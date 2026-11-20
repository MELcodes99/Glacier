// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Uniswap SwapRouter02 (IV3SwapRouter): no deadline field.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IFeed {
    function decimals() external view returns (uint8);
}

interface ICube {
    function tokens() external view returns (address[] memory);
    function weights() external view returns (uint256[] memory);
    function feeds() external view returns (address[] memory);
    function holdings() external view returns (uint256[] memory);
    function priceOf(uint256 i) external view returns (uint256 price, uint256 updatedAt, bool ok);
    function totalSupply() external view returns (uint256);
    function seed(uint256[] calldata amounts, address receiver) external returns (uint256 shares);
    function join(uint256 shares, address receiver, uint256[] calldata maxAmounts) external returns (uint256[] memory);
    function exitFor(address holder, uint256 shares, uint256[] calldata minAmounts, address to)
        external
        returns (uint256[] memory);
}

/// @title GlacierRouter
/// @notice USDC in, Cube shares out (and back). Every swap goes through Uniswap v3
///         with a minimum output derived from the Chainlink price, so a thin or
///         manipulated pool cannot fill far from fair value.
contract GlacierRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000; // 10% hard ceiling

    ISwapRouter02 public immutable swapRouter;
    IERC20 public immutable usdc;
    uint256 public immutable usdcUnit; // 10**usdcDecimals

    mapping(address token => uint24 fee) public poolFee; // Uniswap v3 fee tier of the USDC/token pool

    event PoolFeeSet(address indexed token, uint24 fee);
    event JoinedWithUSDC(address indexed cube, address indexed receiver, uint256 usdcIn, uint256 shares);
    event ExitedToUSDC(address indexed cube, address indexed holder, uint256 shares, uint256 usdcOut);

    constructor(address owner_, address swapRouter_, address usdc_) Ownable(owner_) {
        swapRouter = ISwapRouter02(swapRouter_);
        usdc = IERC20(usdc_);
        usdcUnit = 10 ** IERC20Metadata(usdc_).decimals();
    }

    function setPoolFee(address token, uint24 fee) external onlyOwner {
        poolFee[token] = fee;
        emit PoolFeeSet(token, fee);
    }

    // ---------------------------------------------------------------- seed

    /// @notice First deposit in USDC: split by target weights, buy each stock, seed the Cube.
    function seedWithUSDC(ICube cube, uint256 usdcIn, uint256 slippageBps, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        require(cube.totalSupply() == 0, "seeded");
        require(slippageBps <= MAX_SLIPPAGE_BPS, "slippage");
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);

        address[] memory toks = cube.tokens();
        uint256[] memory w = cube.weights();
        uint256[] memory amounts = new uint256[](toks.length);
        uint256 spent;
        for (uint256 i; i < toks.length; ++i) {
            uint256 part = i == toks.length - 1 ? usdcIn - spent : Math.mulDiv(usdcIn, w[i], BPS);
            spent += part;
            amounts[i] = _buy(cube, i, toks[i], part, slippageBps);
            IERC20(toks[i]).forceApprove(address(cube), amounts[i]);
        }
        shares = cube.seed(amounts, receiver);
        emit JoinedWithUSDC(address(cube), receiver, usdcIn, shares);
    }

    // ---------------------------------------------------------------- join

    /// @notice Buy into a seeded Cube with USDC. USDC is split by each stock's current
    ///         share of the Cube's value; leftover stock dust is refunded to `receiver`.
    function joinWithUSDC(ICube cube, uint256 usdcIn, uint256 slippageBps, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        uint256 supply = cube.totalSupply();
        require(supply > 0, "not seeded");
        require(slippageBps <= MAX_SLIPPAGE_BPS, "slippage");
        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);

        address[] memory toks = cube.tokens();
        uint256[] memory bals = cube.holdings();
        uint256[] memory vals = _values(cube, toks, bals);
        uint256 nav;
        for (uint256 i; i < vals.length; ++i) nav += vals[i];
        require(nav > 0, "empty");

        uint256[] memory outs = new uint256[](toks.length);
        uint256 spent;
        shares = type(uint256).max;
        for (uint256 i; i < toks.length; ++i) {
            uint256 part = i == toks.length - 1 ? usdcIn - spent : Math.mulDiv(usdcIn, vals[i], nav);
            spent += part;
            outs[i] = _buy(cube, i, toks[i], part, slippageBps);
            uint256 s = Math.mulDiv(outs[i], supply, bals[i]);
            if (s < shares) shares = s;
            IERC20(toks[i]).forceApprove(address(cube), outs[i]);
        }
        require(shares > 0 && shares >= minShares, "min shares");

        uint256[] memory used = cube.join(shares, receiver, outs);
        for (uint256 i; i < toks.length; ++i) {
            IERC20(toks[i]).forceApprove(address(cube), 0);
            uint256 left = outs[i] - used[i];
            if (left > 0) IERC20(toks[i]).safeTransfer(receiver, left);
        }
        emit JoinedWithUSDC(address(cube), receiver, usdcIn, shares);
    }

    // ---------------------------------------------------------------- exit

    /// @notice Exit to USDC in one call. Holder must first call cube.setOperator(router, true).
    function exitToUSDC(ICube cube, uint256 shares, uint256 slippageBps, uint256 minUsdcOut)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        require(slippageBps <= MAX_SLIPPAGE_BPS, "slippage");
        address[] memory toks = cube.tokens();
        uint256[] memory mins = new uint256[](toks.length);
        uint256[] memory amounts = cube.exitFor(msg.sender, shares, mins, address(this));
        for (uint256 i; i < toks.length; ++i) {
            if (amounts[i] > 0) usdcOut += _sell(cube, i, toks[i], amounts[i], slippageBps);
        }
        require(usdcOut >= minUsdcOut, "min usdc");
        usdc.safeTransfer(msg.sender, usdcOut);
        emit ExitedToUSDC(address(cube), msg.sender, shares, usdcOut);
    }

    // ---------------------------------------------------------------- internals

    function _scale(ICube cube, uint256 i, address token) internal view returns (uint256) {
        address feed = cube.feeds()[i];
        return 10 ** (uint256(IERC20Metadata(token).decimals()) + IFeed(feed).decimals());
    }

    function _price(ICube cube, uint256 i) internal view returns (uint256 p) {
        bool ok;
        (p,, ok) = cube.priceOf(i);
        require(ok, "bad price");
    }

    function _values(ICube cube, address[] memory toks, uint256[] memory bals)
        internal
        view
        returns (uint256[] memory vals)
    {
        vals = new uint256[](toks.length);
        for (uint256 i; i < toks.length; ++i) {
            vals[i] = Math.mulDiv(bals[i] * _price(cube, i), 1e18, _scale(cube, i, toks[i]));
        }
    }

    /// @dev USDC -> stock. Minimum out = fair amount at the Chainlink price minus slippage.
    function _buy(ICube cube, uint256 i, address token, uint256 usdcAmt, uint256 slippageBps)
        internal
        returns (uint256 out)
    {
        uint24 fee = poolFee[token];
        require(fee != 0, "no pool");
        uint256 fair = Math.mulDiv(usdcAmt, _scale(cube, i, token), _price(cube, i) * usdcUnit);
        uint256 minOut = Math.mulDiv(fair, BPS - slippageBps, BPS);
        usdc.forceApprove(address(swapRouter), usdcAmt);
        out = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: token,
                fee: fee,
                recipient: address(this),
                amountIn: usdcAmt,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Stock -> USDC with the same Chainlink-based floor.
    function _sell(ICube cube, uint256 i, address token, uint256 amt, uint256 slippageBps)
        internal
        returns (uint256 out)
    {
        uint24 fee = poolFee[token];
        require(fee != 0, "no pool");
        uint256 fair = Math.mulDiv(amt * _price(cube, i), usdcUnit, _scale(cube, i, token));
        uint256 minOut = Math.mulDiv(fair, BPS - slippageBps, BPS);
        IERC20(token).forceApprove(address(swapRouter), amt);
        out = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: address(usdc),
                fee: fee,
                recipient: address(this),
                amountIn: amt,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
