// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IStockRegistry {
    function feedOf(address token) external view returns (address);
}

/// @title Cube
/// @notice A basket of up to 5 Base tokenized stocks. Holders join in kind
///         (proportional to current holdings) and exit in kind. Shares are
///         non-transferable so each holder's cost basis stays exact.
/// @dev    Value is read from Chainlink feeds, which already include the B20
///         multiplier: value = rawBalance * feedPrice. Never multiply again.
contract Cube is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant WEIGHT_TOLERANCE_BPS = 100; // seed must match weights within 1%
    uint256 public constant MIN_SEED_VALUE = 1e18; // $1 (18-decimal USD)

    address public immutable factory;
    address public immutable creator;
    uint256 public immutable createdAt;
    string public imageURI;

    address[] internal _tokens;
    uint256[] internal _weights; // bps, sums to 10_000
    address[] internal _feeds;
    uint256[] internal _scale; // 10**(tokenDecimals + feedDecimals)

    uint256 public entryFeeBps;
    uint256 public profitFeeBps;

    mapping(address holder => uint256 usd18) public costBasis;
    uint256 public holders;

    bool private _feeMove; // only internal fee transfers may move shares between holders

    /// @notice Holders can approve an operator (the Router) to exit on their behalf.
    mapping(address holder => mapping(address operator => bool)) public isOperator;

    event Seeded(address indexed receiver, uint256 shares, uint256 valueUsd);
    event Joined(address indexed payer, address indexed receiver, uint256 shares, uint256 feeShares, uint256 valueUsd);
    event Exited(address indexed holder, uint256 shares, uint256 feeShares, uint256 valueUsd, uint256 profitUsd);
    event FeesLowered(uint256 entryFeeBps, uint256 profitFeeBps);
    event OperatorSet(address indexed holder, address indexed operator, bool approved);

    error NonTransferable();
    error BadPrice(address token);
    error Slippage(uint256 index);
    error NotCreator();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory imageURI_,
        address creator_,
        address registry_,
        address[] memory tokens_,
        uint256[] memory weights_,
        uint256 entryFeeBps_,
        uint256 profitFeeBps_
    ) ERC20(name_, symbol_) {
        factory = msg.sender;
        creator = creator_;
        createdAt = block.timestamp;
        imageURI = imageURI_;
        entryFeeBps = entryFeeBps_;
        profitFeeBps = profitFeeBps_;
        for (uint256 i; i < tokens_.length; ++i) {
            address feed = IStockRegistry(registry_).feedOf(tokens_[i]);
            _tokens.push(tokens_[i]);
            _weights.push(weights_[i]);
            _feeds.push(feed);
            _scale.push(10 ** (uint256(IERC20Metadata(tokens_[i]).decimals()) + IAggregatorV3(feed).decimals()));
        }
    }

    // ---------------------------------------------------------------- views

    function tokens() external view returns (address[] memory) { return _tokens; }
    function weights() external view returns (uint256[] memory) { return _weights; }
    function feeds() external view returns (address[] memory) { return _feeds; }

    /// @notice Latest feed price and its update time. ok=false on a non-positive answer.
    function priceOf(uint256 i) public view returns (uint256 price, uint256 updatedAt, bool ok) {
        (, int256 answer,, uint256 upd,) = IAggregatorV3(_feeds[i]).latestRoundData();
        if (answer <= 0) return (0, upd, false);
        return (uint256(answer), upd, true);
    }

    /// @notice USD value (18 decimals) of a set of raw token amounts. ok=false if any price is bad.
    function valueOf(uint256[] memory amounts) public view returns (uint256 usd, bool ok) {
        ok = true;
        for (uint256 i; i < _tokens.length; ++i) {
            (uint256 p,, bool good) = priceOf(i);
            if (!good) return (0, false);
            usd += Math.mulDiv(amounts[i] * p, 1e18, _scale[i]);
        }
    }

    function holdings() public view returns (uint256[] memory bals) {
        bals = new uint256[](_tokens.length);
        for (uint256 i; i < _tokens.length; ++i) bals[i] = IERC20(_tokens[i]).balanceOf(address(this));
    }

    /// @notice Total value of the Cube in USD (18 decimals).
    function navUsd() public view returns (uint256 usd, bool ok) { return valueOf(holdings()); }

    /// @notice Raw token amounts needed to mint `shares` (rounded up in the Cube's favour).
    function previewJoin(uint256 shares) public view returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        uint256[] memory bals = holdings();
        amounts = new uint256[](bals.length);
        for (uint256 i; i < bals.length; ++i) amounts[i] = Math.mulDiv(bals[i], shares, supply, Math.Rounding.Ceil);
    }

    /// @notice Raw token amounts returned for burning `shares` (rounded down).
    function previewExit(uint256 shares) public view returns (uint256[] memory amounts) {
        uint256 supply = totalSupply();
        uint256[] memory bals = holdings();
        amounts = new uint256[](bals.length);
        for (uint256 i; i < bals.length; ++i) amounts[i] = Math.mulDiv(bals[i], shares, supply);
    }

    // ---------------------------------------------------------------- seed

    /// @notice First deposit. Amounts must match the target weights by value (within 1%).
    ///         Mints 1 share per $1 deposited.
    function seed(uint256[] calldata amounts, address receiver) external nonReentrant returns (uint256 shares) {
        require(totalSupply() == 0, "seeded");
        require(amounts.length == _tokens.length, "length");
        (uint256 value, bool ok) = valueOf(amounts);
        require(ok, "bad price");
        require(value >= MIN_SEED_VALUE, "seed too small");

        for (uint256 i; i < amounts.length; ++i) {
            (uint256 p,,) = priceOf(i);
            uint256 v = Math.mulDiv(amounts[i] * p, 1e18, _scale[i]);
            uint256 actualBps = Math.mulDiv(v, BPS, value);
            uint256 diff = actualBps > _weights[i] ? actualBps - _weights[i] : _weights[i] - actualBps;
            require(diff <= WEIGHT_TOLERANCE_BPS, "weights");
            IERC20(_tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
        }
        shares = value;
        _mintWithFee(msg.sender, receiver, shares, value);
        emit Seeded(receiver, shares, value);
    }

    // ---------------------------------------------------------------- join

    /// @notice Mint `shares` by depositing each stock pro rata to current holdings.
    ///         Payer is msg.sender (a user or the Router). Entry fee is taken in shares.
    function join(uint256 shares, address receiver, uint256[] calldata maxAmounts)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        require(totalSupply() > 0, "not seeded");
        require(shares > 0, "zero");
        require(maxAmounts.length == _tokens.length, "length");
        amounts = previewJoin(shares);
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] > maxAmounts[i]) revert Slippage(i);
            IERC20(_tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
        }
        (uint256 value, bool ok) = valueOf(amounts);
        require(ok, "bad price");
        _mintWithFee(msg.sender, receiver, shares, value);
    }

    function _mintWithFee(address payer, address receiver, uint256 shares, uint256 value) internal {
        uint256 fee = Math.mulDiv(shares, entryFeeBps, BPS);
        if (fee > 0) _mint(creator, fee);
        _mint(receiver, shares - fee);
        costBasis[receiver] += value; // cost = full value paid, fee included
        emit Joined(payer, receiver, shares - fee, fee, value);
    }

    // ---------------------------------------------------------------- exit

    /// @notice Burn `shares` for the pro-rata stocks. If the position is in profit,
    ///         the profit fee is paid to the creator in shares first. Exit never
    ///         reverts on a bad price: the profit fee is skipped instead.
    function exit(uint256 shares, uint256[] calldata minAmounts) external nonReentrant returns (uint256[] memory) {
        return _exit(msg.sender, shares, minAmounts, msg.sender);
    }

    /// @notice Exit for `holder`, sending the stocks to `to`. Caller must be the holder or its operator.
    function exitFor(address holder, uint256 shares, uint256[] calldata minAmounts, address to)
        external
        nonReentrant
        returns (uint256[] memory)
    {
        require(msg.sender == holder || isOperator[holder][msg.sender], "not operator");
        return _exit(holder, shares, minAmounts, to);
    }

    function setOperator(address operator, bool approved) external {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
    }

    function _exit(address holder, uint256 shares, uint256[] calldata minAmounts, address to)
        internal
        returns (uint256[] memory amounts)
    {
        uint256 bal = balanceOf(holder);
        require(shares > 0 && shares <= bal, "shares");
        require(minAmounts.length == _tokens.length, "length");

        uint256 costPortion = Math.mulDiv(costBasis[holder], shares, bal);
        costBasis[holder] -= costPortion;

        uint256[] memory gross = previewExit(shares);
        (uint256 value, bool ok) = valueOf(gross);
        uint256 feeShares;
        uint256 profit;
        if (ok && value > costPortion && profitFeeBps > 0 && holder != creator) {
            profit = value - costPortion;
            uint256 feeValue = Math.mulDiv(profit, profitFeeBps, BPS);
            feeShares = Math.mulDiv(shares, feeValue, value);
            _feeMove = true;
            _transfer(holder, creator, feeShares);
            _feeMove = false;
        }

        uint256 burnShares = shares - feeShares;
        amounts = previewExit(burnShares);
        _burn(holder, burnShares);
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] < minAmounts[i]) revert Slippage(i);
            IERC20(_tokens[i]).safeTransfer(to, amounts[i]);
        }
        emit Exited(holder, burnShares, feeShares, value, profit);
    }

    // ---------------------------------------------------------------- creator

    /// @notice Creator may only lower fees, never raise them.
    function lowerFees(uint256 newEntryBps, uint256 newProfitBps) external {
        if (msg.sender != creator) revert NotCreator();
        require(newEntryBps <= entryFeeBps && newProfitBps <= profitFeeBps, "only lower");
        entryFeeBps = newEntryBps;
        profitFeeBps = newProfitBps;
        emit FeesLowered(newEntryBps, newProfitBps);
    }

    // ---------------------------------------------------------------- shares

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && !_feeMove) revert NonTransferable();
        uint256 fromBefore = from == address(0) ? 0 : balanceOf(from);
        uint256 toBefore = to == address(0) ? 0 : balanceOf(to);
        super._update(from, to, value);
        if (to != address(0) && toBefore == 0 && value > 0) holders++;
        if (from != address(0) && fromBefore > 0 && balanceOf(from) == 0) holders--;
    }
}
