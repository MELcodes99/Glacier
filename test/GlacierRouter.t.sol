// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {CubeFactory} from "../src/CubeFactory.sol";
import {Cube} from "../src/Cube.sol";
import {GlacierRouter, ICube, ISwapRouter02} from "../src/GlacierRouter.sol";

contract MToken is ERC20 {
    uint8 private immutable _d;
    constructor(string memory s, uint8 d) ERC20(s, s) { _d = d; }
    function decimals() public view override returns (uint8) { return _d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MFeed {
    int256 public answer;
    constructor(int256 a) { answer = a; }
    function set(int256 a) external { answer = a; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// @dev Fills at the feed price minus `haircutBps`, minting the output token.
contract MSwapRouter {
    MToken public usdc;
    mapping(address => MFeed) public feedOf;
    uint256 public haircutBps = 30; // like a 0.3% pool

    constructor(MToken usdc_) { usdc = usdc_; }
    function setFeed(address t, MFeed f) external { feedOf[t] = f; }
    function setHaircut(uint256 h) external { haircutBps = h; }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external returns (uint256 out) {
        ERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        if (p.tokenIn == address(usdc)) {
            uint256 price = uint256(feedOf[p.tokenOut].answer()); // 8 dec, stock 8 dec, usdc 6 dec
            out = p.amountIn * 1e10 / price;
        } else {
            uint256 price = uint256(feedOf[p.tokenIn].answer());
            out = p.amountIn * price / 1e10;
        }
        out = out * (10_000 - haircutBps) / 10_000;
        require(out >= p.amountOutMinimum, "Too little received");
        MToken(p.tokenOut).mint(p.recipient, out);
    }
}

contract GlacierRouterTest is Test {
    StockRegistry registry;
    CubeFactory factory;
    GlacierRouter router;
    MSwapRouter swap;
    MToken usdc; MToken a; MToken b;
    MFeed fa; MFeed fb;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    Cube cube;

    function setUp() public {
        usdc = new MToken("USDC", 6);
        a = new MToken("AAPLc", 8); b = new MToken("NVDAc", 8);
        fa = new MFeed(350e8); fb = new MFeed(140e8);
        registry = new StockRegistry(address(this));
        registry.setStock(address(a), address(fa));
        registry.setStock(address(b), address(fb));
        factory = new CubeFactory(address(registry));
        swap = new MSwapRouter(usdc);
        swap.setFeed(address(a), fa); swap.setFeed(address(b), fb);
        router = new GlacierRouter(address(this), address(swap), address(usdc));
        router.setPoolFee(address(a), 3000);
        router.setPoolFee(address(b), 3000);

        address[] memory t = new address[](2); t[0] = address(a); t[1] = address(b);
        uint256[] memory w = new uint256[](2); w[0] = 5_000; w[1] = 5_000;
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

    function test_SeedWithUSDC() public {
        _seed();
        (uint256 nav,) = cube.navUsd();
        assertApproxEqRel(nav, 99.7e18, 0.001e18); // $100 minus 0.3% swap cost
        assertGt(cube.balanceOf(creator), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_JoinWithUSDC() public {
        _seed();
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        uint256 shares = router.joinWithUSDC(ICube(address(cube)), 50e6, 100, 1, alice);
        vm.stopPrank();
        assertGt(shares, 0);
        // alice holds ~$49.85 of value after the 0.3% swap, minus the 1% entry fee in shares
        uint256 aliceShares = cube.balanceOf(alice);
        (uint256 nav,) = cube.navUsd();
        uint256 aliceValue = nav * aliceShares / cube.totalSupply();
        assertApproxEqRel(aliceValue, 49.35e18, 0.005e18);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(a.balanceOf(address(router)), 0);
        assertEq(b.balanceOf(address(router)), 0);
    }

    function test_ExitToUSDC() public {
        _seed();
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        router.joinWithUSDC(ICube(address(cube)), 50e6, 100, 1, alice);
        cube.setOperator(address(router), true);
        uint256 before = usdc.balanceOf(alice);
        uint256 out = router.exitToUSDC(ICube(address(cube)), cube.balanceOf(alice), 100, 1);
        vm.stopPrank();
        assertEq(cube.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice) - before, out);
        assertApproxEqRel(out, 49.2e6, 0.005e18); // two 0.3% swaps + 1% entry fee
    }

    function test_ExitNeedsOperator() public {
        _seed();
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        router.joinWithUSDC(ICube(address(cube)), 50e6, 100, 1, alice);
        uint256 s = cube.balanceOf(alice);
        vm.expectRevert(bytes("not operator"));
        router.exitToUSDC(ICube(address(cube)), s, 100, 1);
        vm.stopPrank();
    }

    function test_BadFillReverts() public {
        swap.setHaircut(500); // pool fills 5% below the Chainlink price
        vm.startPrank(creator);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("Too little received"));
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
        router.setPoolFee(address(b), 0);
        vm.startPrank(creator);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("no pool"));
        router.seedWithUSDC(ICube(address(cube)), 100e6, 100, creator);
        vm.stopPrank();
    }
}
