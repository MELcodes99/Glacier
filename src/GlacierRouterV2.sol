// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Uniswap v3-style concentrated-liquidity pool (Aerodrome CL on Base).
interface ICLPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function factory() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
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

/// @title GlacierRouterV2
/// @notice USDC in, Cube shares out (and back), swapping directly against the deep Aerodrome
///         CL pools on Base. Same interface as GlacierRouter v1.
/// @dev Every swap has a minimum output derived from the Chainlink price (as in v1), every pool
///      must be registered by an allowed factory, and the swap callback only pays the pool that
///      is mid-swap. A swap that cannot fill the full input reverts instead of leaving dust.
contract GlacierRouterV2 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000; // 10% hard ceiling
    uint160 internal constant MIN_SQRT_RATIO_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_RATIO_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    IERC20 public immutable usdc;
    uint256 public immutable usdcUnit; // 10**usdcDecimals

    mapping(address poolFactory => bool) public allowedPoolFactory;
    mapping(address token => address pool) public poolOf; // USDC/token pool used for each stock

    address private _activePool;

    event PoolFactoryAllowed(address indexed poolFactory, bool allowed);
    event PoolSet(address indexed token, address indexed pool);
    event JoinedWithUSDC(address indexed cube, address indexed receiver, uint256 usdcIn, uint256 shares);
    event ExitedToUSDC(address indexed cube, address indexed holder, uint256 shares, uint256 usdcOut);

    error FactoryNotAllowed(address poolFactory);
    error NotCanonicalPool(address pool);
    error NotUsdcPair(address pool);
    error NoPool(address token);
    error UnexpectedCallback();
    error PartialFill();
    error BadDelta();

    constructor(address owner_, address usdc_) Ownable(owner_) {
        usdc = IERC20(usdc_);
        usdcUnit = 10 ** IERC20Metadata(usdc_).decimals();
    }

    // ---------------------------------------------------------------- admin

    function setPoolFactory(address poolFactory, bool allowed) external onlyOwner {
        allowedPoolFactory[poolFactory] = allowed;
        emit PoolFactoryAllowed(poolFactory, allowed);
    }

    /// @notice Set the USDC/token pool for a stock. Checked against an allowed factory.
    function setPool(address token, ICLPool pool) external onlyOwner {
        address t0 = pool.token0();
        address t1 = pool.token1();
        if (!((t0 == address(usdc) && t1 == token) || (t1 == address(usdc) && t0 == token))) {
            revert NotUsdcPair(address(pool));
        }
        address f = pool.factory();
        if (!allowedPoolFactory[f]) revert FactoryNotAllowed(f);
        if (ICLFactory(f).getPool(t0, t1, pool.tickSpacing()) != address(pool)) revert NotCanonicalPool(address(pool));
        poolOf[token] = address(pool);
        emit PoolSet(token, address(pool));
    }

    function removePool(address token) external onlyOwner {
        delete poolOf[token];
        emit PoolSet(token, address(0));
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
        for (uint256 i; i < toks.length; ++i) {
            IERC20(toks[i]).forceApprove(address(cube), 0);
        }
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

    /// @notice Exit to USDC in one call. Holder must first call cube.setOperator(routerV2, true).
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

    // ---------------------------------------------------------------- swap callback

    /// @notice Called by the pool during a swap to collect the input. Only the active pool may call.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _activePool || msg.sender == address(0)) revert UnexpectedCallback();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
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
        uint256 fair = Math.mulDiv(usdcAmt, _scale(cube, i, token), _price(cube, i) * usdcUnit);
        uint256 minOut = Math.mulDiv(fair, BPS - slippageBps, BPS);
        out = _swap(token, address(usdc), token, usdcAmt);
        require(out >= minOut, "too little received");
    }

    /// @dev Stock -> USDC with the same Chainlink-based floor.
    function _sell(ICube cube, uint256 i, address token, uint256 amt, uint256 slippageBps)
        internal
        returns (uint256 out)
    {
        uint256 fair = Math.mulDiv(amt * _price(cube, i), usdcUnit, _scale(cube, i, token));
        uint256 minOut = Math.mulDiv(fair, BPS - slippageBps, BPS);
        out = _swap(token, token, address(usdc), amt);
        require(out >= minOut, "too little received");
    }

    /// @dev Exact-input swap on the stock's registered pool. Output comes to this router.
    function _swap(address stock, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 out) {
        address pool = poolOf[stock];
        if (pool == address(0)) revert NoPool(stock);
        if (amountIn == 0) return 0;
        bool zeroForOne = tokenIn < tokenOut;

        _activePool = pool;
        (int256 a0, int256 a1) = ICLPool(pool).swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
            abi.encode(tokenIn)
        );
        _activePool = address(0);

        (int256 paid, int256 received) = zeroForOne ? (a0, a1) : (a1, a0);
        if (received > 0 || paid < 0) revert BadDelta();
        if (uint256(paid) != amountIn) revert PartialFill(); // never leave unspent input behind
        out = uint256(-received);
    }
}
