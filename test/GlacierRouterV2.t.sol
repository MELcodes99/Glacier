// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {CubeFactory} from "../src/CubeFactory.sol";
import {Cube} from "../src/Cube.sol";
import {GlacierRouterV2, ICube, ICLPool} from "../src/GlacierRouterV2.sol";

contract V2Token is ERC20 {
    uint8 private immutable _d;
    constructor(string memory s, uint8 d) ERC20(s, s) { _d = d; }
    function decimals() public view override returns (uint8) { return _d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burn(address from, uint256 a) external { _burn(from, a); }
}

contract V2Feed {
    int256 public answer;
    constructor(int256 a) { answer = a; }
    function set(int256 a) external { answer = a; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

contract V2CLFactory {
    mapping(bytes32 => address) internal _pools;
    function register(address a, address b, int24 ts, address pool) external {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        _pools[keccak256(abi.encode(t0, t1, ts))] = pool;
    }
    function getPool(address a, address b, int24 ts) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return _pools[keccak256(abi.encode(t0, t1, ts))];
    }
}

interface IV3Callback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @dev Aerodrome-CL-style pool: fills at the feed price minus `haircutBps`, collects input via the callback.
contract V2CLPool {
    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    int24 public constant tickSpacing = 10;
    address public immutable usdc;
    address public immutable stock;
    V2Feed public immutable feed;
    uint256 public haircutBps = 30; // like a 0.3% pool
    bool public halfFill; // simulate running out of liquidity

    constructor(address usdc_, address stock_, V2Feed feed_, address factory_) {
        (token0, token1) = usdc_ < stock_ ? (usdc_, stock_) : (stock_, usdc_);
        usdc = usdc_;
        stock = stock_;
        feed = feed_;
        factory = factory_;
    }

    function setHaircut(uint256 h) external { haircutBps = h; }
    function setHalfFill(bool h) external { halfFill = h; }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact in only");
        uint256 amountIn = uint256(amountSpecified);
        if (halfFill) amountIn /= 2;
        address tIn = zeroForOne ? token0 : token1;
        address tOut = zeroForOne ? token1 : token0;
        uint256 price = uint256(feed.answer()); // 8 dec; stock 8 dec; usdc 6 dec
        uint256 out = tIn == usdc ? (amountIn * 1e10) / price : (amountIn * price) / 1e10;
        out = (out * (10_000 - haircutBps)) / 10_000;
        V2Token(tOut).mint(recipient, out);

        (amount0, amount1) = zeroForOne ? (int256(amountIn), -int256(out)) : (-int256(out), int256(amountIn));
        uint256 before = ERC20(tIn).balanceOf(address(this));
        IV3Callback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(ERC20(tIn).balanceOf(address(this)) >= before + amountIn, "not paid");
        V2Token(tIn).burn(address(this), amountIn);
    }
}

contract GlacierRouterV2Test is Test {
    StockRegistry registry;
    CubeFactory factory;
    GlacierRouterV2 router;
    V2CLFactory clFactory;
    V2CLPool poolA;
    V2CLPool poolB;
    V2Token usdc;
    V2Token a;
    V2Token b;
    V2Feed fa;
    V2Feed fb;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    Cube cube;

    function setUp() public {
        usdc = new V2Token("USDC", 6);
        a = new V2Token("AAPLc", 8);
        b = new V2Token("NVDAc", 8);
        fa = new V2Feed(350e8);
        fb = new V2Feed(140e8);
        registry = new StockRegistry(address(this));
        registry.setStock(address(a), address(fa));
        registry.setStock(address(b), address(fb));
        factory = new CubeFactory(address(registry));

        clFactory = new V2CLFactory();
        poolA = new V2CLPool(address(usdc), address(a), fa, address(clFactory));
        poolB = new V2CLPool(address(usdc), address(b), fb, address(clFactory));
        clFactory.register(address(usdc), address(a), 10, address(poolA));
        clFactory.register(address(usdc), address(b), 10, address(poolB));

        router = new GlacierRouterV2(address(this), address(usdc));
        router.setPoolFactory(address(clFactory), true);
        router.setPool(address(a), ICLPool(address(poolA)));
        router.setPool(address(b), ICLPool(address(poolB)));

        address[] memory t = new address[](2);
        t[0] = address(a);
        t[1] = address(b);
        uint256[] memory w = new uint256[](2);
        w[0] = 5_000;
        w[1] = 5_000;
        vm.prank(creator);
        cube = Cube(factory.createCube("Big Two", "BIG2", "ipfs://x", t, w, 100, 2_000));

        usdc.mint(creator, 1_000e6);
        usdc.mint(alice, 1_000e6);
    }

    function _seed() internal {
        vm.startPrank(creator);
        usdc.approve(address(router), type(uint256).max);
        router.seedWithUSDC(ICube(address(cube)), 100e6, 100, creator);
        vm.stopPrank();
    }

    function _join(uint256 amt) internal {
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        router.joinWithUSDC(ICube(address(cube)), amt, 100, 1, alice);
        vm.stopPrank();
    }

    function _routerIsEmpty() internal view {
        assertEq(usdc.balanceOf(address(router)), 0, "router usdc");
        assertEq(a.balanceOf(address(router)), 0, "router a");
        assertEq(b.balanceOf(address(router)), 0, "router b");
    }

    // ---------------------------------------------------------------- same behaviour as v1

    function test_SeedWithUSDC() public {
        _seed();
        (uint256 nav,) = cube.navUsd();
        assertApproxEqRel(nav, 99.7e18, 0.001e18); // $100 minus 0.3% swap cost
        assertGt(cube.balanceOf(creator), 0);
        _routerIsEmpty();
    }

    function test_JoinWithUSDC() public {
        _seed();
        _join(50e6);
        uint256 aliceShares = cube.balanceOf(alice);
        (uint256 nav,) = cube.navUsd();
        uint256 aliceValue = (nav * aliceShares) / cube.totalSupply();
        assertApproxEqRel(aliceValue, 49.35e18, 0.005e18); // 0.3% swap + 1% entry fee
        _routerIsEmpty();
    }

    function test_ExitToUSDC() public {
        _seed();
        _join(50e6);
        vm.startPrank(alice);
        cube.setOperator(address(router), true);
        uint256 before = usdc.balanceOf(alice);
        uint256 out = router.exitToUSDC(ICube(address(cube)), cube.balanceOf(alice), 100, 1);
        vm.stopPrank();
        assertEq(cube.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice) - before, out);
        assertApproxEqRel(out, 49.2e6, 0.005e18); // two 0.3% swaps + 1% entry fee
        _routerIsEmpty();
    }

    function test_ExitNeedsOperator() public {
        _seed();
        _join(50e6);
        uint256 s = cube.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("not operator"));
        router.exitToUSDC(ICube(address(cube)), s, 100, 1);
    }

    function test_BadFillReverts() public {
        poolB.setHaircut(500); // pool fills 5% below the Chainlink price
        vm.startPrank(creator);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("too little received"));
        router.seedWithUSDC(ICube(address(cube)), 100e6, 100, creator); // 1% tolerance
        vm.stopPrank();
    }

    function test_SlippageCeiling() public {
        vm.startPrank(creator);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("slippage"));
        router.seedWithUSDC(ICube(address(cube)), 100e6, 1_001, creator);
        vm.stopPrank();
    }

    function test_NoPoolReverts() public {
        router.removePool(address(b));
        vm.startPrank(creator);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(GlacierRouterV2.NoPool.selector, address(b)));
        router.seedWithUSDC(ICube(address(cube)), 100e6, 100, creator);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- new in v2

    function test_PartialFillReverts() public {
        poolA.setHalfFill(true);
        vm.startPrank(creator);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(GlacierRouterV2.PartialFill.selector);
        router.seedWithUSDC(ICube(address(cube)), 100e6, 100, creator);
        vm.stopPrank();
    }

    function test_CallbackOnlyFromActivePool() public {
        vm.expectRevert(GlacierRouterV2.UnexpectedCallback.selector);
        router.uniswapV3SwapCallback(1, 0, abi.encode(address(usdc)));

        vm.prank(address(poolA)); // a registered pool, but no swap in progress
        vm.expectRevert(GlacierRouterV2.UnexpectedCallback.selector);
        router.uniswapV3SwapCallback(1, 0, abi.encode(address(usdc)));
    }

    function test_SetPoolRejectsWrongPair() public {
        vm.expectRevert(abi.encodeWithSelector(GlacierRouterV2.NotUsdcPair.selector, address(poolA)));
        router.setPool(address(b), ICLPool(address(poolA))); // poolA is USDC/A, not USDC/B
    }

    function test_SetPoolRejectsUnknownFactory() public {
        V2CLFactory rogue = new V2CLFactory();
        V2CLPool fake = new V2CLPool(address(usdc), address(a), fa, address(rogue));
        rogue.register(address(usdc), address(a), 10, address(fake));
        vm.expectRevert(abi.encodeWithSelector(GlacierRouterV2.FactoryNotAllowed.selector, address(rogue)));
        router.setPool(address(a), ICLPool(address(fake)));
    }

    function test_SetPoolRejectsNonCanonicalPool() public {
        V2CLPool impostor = new V2CLPool(address(usdc), address(a), fa, address(clFactory)); // never registered
        vm.expectRevert(abi.encodeWithSelector(GlacierRouterV2.NotCanonicalPool.selector, address(impostor)));
        router.setPool(address(a), ICLPool(address(impostor)));
    }

    function test_OnlyOwnerSetsPools() public {
        vm.prank(alice);
        vm.expectRevert();
        router.setPool(address(a), ICLPool(address(poolA)));
    }
}
