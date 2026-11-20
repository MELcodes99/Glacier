// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {StockRegistry} from "../src/StockRegistry.sol";
import {CubeFactory} from "../src/CubeFactory.sol";
import {Cube} from "../src/Cube.sol";

contract MockStock is ERC20 {
    constructor(string memory s) ERC20(s, s) {}
    function decimals() public pure override returns (uint8) { return 8; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    constructor(int256 a) { set(a); }
    function set(int256 a) public { answer = a; updatedAt = block.timestamp; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract CubeTest is Test {
    StockRegistry registry;
    CubeFactory factory;
    MockStock a; MockStock b;
    MockFeed fa; MockFeed fb;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");

    function setUp() public {
        registry = new StockRegistry(address(this));
        factory = new CubeFactory(address(registry));
        a = new MockStock("AAPLc"); b = new MockStock("NVDAc");
        fa = new MockFeed(100e8); // $100
        fb = new MockFeed(50e8);  // $50
        registry.setStock(address(a), address(fa));
        registry.setStock(address(b), address(fb));
        a.mint(creator, 1_000e8); b.mint(creator, 1_000e8);
        a.mint(alice, 1_000e8);   b.mint(alice, 1_000e8);
    }

    function _pair() internal view returns (address[] memory t, uint256[] memory w) {
        t = new address[](2); t[0] = address(a); t[1] = address(b);
        w = new uint256[](2); w[0] = 6_000; w[1] = 4_000;
    }

    function _create(uint256 entry, uint256 profit) internal returns (Cube cube) {
        (address[] memory t, uint256[] memory w) = _pair();
        vm.prank(creator);
        cube = Cube(factory.createCube("Mega Tech", "MEGA", "ipfs://img", t, w, entry, profit));
    }

    function _seed(Cube cube) internal {
        // $600 of A (6 tokens) + $400 of B (8 tokens) = $1,000 at 60/40
        uint256[] memory amts = new uint256[](2); amts[0] = 6e8; amts[1] = 8e8;
        vm.startPrank(creator);
        a.approve(address(cube), type(uint256).max);
        b.approve(address(cube), type(uint256).max);
        cube.seed(amts, creator);
        vm.stopPrank();
    }

    function _join(Cube cube, address who, uint256 shares) internal {
        uint256[] memory maxA = cube.previewJoin(shares);
        vm.startPrank(who);
        a.approve(address(cube), type(uint256).max);
        b.approve(address(cube), type(uint256).max);
        cube.join(shares, who, maxA);
        vm.stopPrank();
    }

    function _exitAll(Cube cube, address who) internal {
        uint256[] memory mins = new uint256[](2);
        uint256 s = cube.balanceOf(who);
        vm.prank(who);
        cube.exit(s, mins);
    }

    // ------------------------------------------------------------ factory rules

    function test_RejectsWeightsNot100() public {
        (address[] memory t, uint256[] memory w) = _pair();
        w[1] = 3_000;
        vm.expectRevert(bytes("weights != 100%"));
        factory.createCube("x", "x", "", t, w, 0, 0);
    }

    function test_RejectsFeeAboveCap() public {
        (address[] memory t, uint256[] memory w) = _pair();
        vm.expectRevert(bytes("fee cap"));
        factory.createCube("x", "x", "", t, w, 301, 0);
    }

    function test_RejectsDuplicate() public {
        (address[] memory t, uint256[] memory w) = _pair();
        t[1] = address(a);
        vm.expectRevert(bytes("duplicate"));
        factory.createCube("x", "x", "", t, w, 0, 0);
    }

    function test_RejectsUnlisted() public {
        (address[] memory t, uint256[] memory w) = _pair();
        t[1] = address(new MockStock("X"));
        vm.expectRevert(bytes("not listed"));
        factory.createCube("x", "x", "", t, w, 0, 0);
    }

    // ------------------------------------------------------------ seed / join / exit

    function test_SeedMintsOneSharePerDollar() public {
        Cube cube = _create(0, 0);
        _seed(cube);
        assertEq(cube.totalSupply(), 1_000e18);
        (uint256 nav,) = cube.navUsd();
        assertEq(nav, 1_000e18);
        assertEq(cube.holders(), 1);
    }

    function test_SeedRejectsWrongWeights() public {
        Cube cube = _create(0, 0);
        uint256[] memory amts = new uint256[](2); amts[0] = 5e8; amts[1] = 10e8; // 50/50
        vm.startPrank(creator);
        a.approve(address(cube), type(uint256).max);
        b.approve(address(cube), type(uint256).max);
        vm.expectRevert(bytes("weights"));
        cube.seed(amts, creator);
        vm.stopPrank();
    }

    function test_JoinExitNoProfitNoFee() public {
        Cube cube = _create(0, 2_000);
        _seed(cube);
        uint256 a0 = a.balanceOf(alice); uint256 b0 = b.balanceOf(alice);
        _join(cube, alice, 100e18);
        _exitAll(cube, alice);
        assertApproxEqAbs(a.balanceOf(alice), a0, 2);
        assertApproxEqAbs(b.balanceOf(alice), b0, 2);
        assertEq(cube.balanceOf(creator), 1_000e18); // no fee shares
    }

    function test_EntryFeeGoesToCreator() public {
        Cube cube = _create(300, 0); // 3%
        _seed(cube);
        uint256 before = cube.balanceOf(creator);
        _join(cube, alice, 100e18);
        assertEq(cube.balanceOf(alice), 97e18);
        assertEq(cube.balanceOf(creator) - before, 3e18);
    }

    function test_ProfitFeeOnGain() public {
        Cube cube = _create(0, 2_000); // 20% of profit
        _seed(cube);
        _join(cube, alice, 100e18); // alice pays $100
        fa.set(200e8);               // A doubles: Cube value 1000 -> 1600 (+60%)
        uint256 creatorBefore = cube.balanceOf(creator);
        _exitAll(cube, alice);
        // alice's $100 is now $160, profit $60, fee $12 = 7.5 shares of 100
        assertApproxEqAbs(cube.balanceOf(creator) - creatorBefore, 7.5e18, 1e12);
        assertEq(cube.balanceOf(alice), 0);
        assertEq(cube.costBasis(alice), 0);
    }

    function test_NoProfitFeeOnLoss() public {
        Cube cube = _create(0, 2_000);
        _seed(cube);
        _join(cube, alice, 100e18);
        fa.set(50e8); // A halves
        uint256 creatorBefore = cube.balanceOf(creator);
        _exitAll(cube, alice);
        assertEq(cube.balanceOf(creator), creatorBefore);
    }

    function test_ExitSkipsFeeOnBadPrice() public {
        Cube cube = _create(0, 2_000);
        _seed(cube);
        _join(cube, alice, 100e18);
        fa.set(0); // broken feed must not trap funds
        uint256 creatorBefore = cube.balanceOf(creator);
        _exitAll(cube, alice);
        assertEq(cube.balanceOf(creator), creatorBefore);
        assertEq(cube.balanceOf(alice), 0);
    }

    function test_SharesAreNonTransferable() public {
        Cube cube = _create(0, 0);
        _seed(cube);
        vm.prank(creator);
        vm.expectRevert(Cube.NonTransferable.selector);
        cube.transfer(alice, 1e18);
    }

    function test_FeesCanOnlyGoDown() public {
        Cube cube = _create(200, 1_000);
        vm.startPrank(creator);
        cube.lowerFees(100, 500);
        vm.expectRevert(bytes("only lower"));
        cube.lowerFees(150, 500);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(Cube.NotCreator.selector);
        cube.lowerFees(0, 0);
    }

    function test_HolderCount() public {
        Cube cube = _create(0, 0);
        _seed(cube);
        _join(cube, alice, 50e18);
        assertEq(cube.holders(), 2);
        _exitAll(cube, alice);
        assertEq(cube.holders(), 1);
    }
}
