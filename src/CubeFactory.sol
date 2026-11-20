// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Cube} from "./Cube.sol";

interface IRegistry {
    function feedOf(address token) external view returns (address);
}

/// @title CubeFactory
/// @notice Creates Cubes: 1 to 5 listed stocks, weights summing to 100%, capped fees.
contract CubeFactory {
    uint256 public constant MAX_STOCKS = 5;
    uint256 public constant MAX_ENTRY_FEE_BPS = 300; // 3%
    uint256 public constant MAX_PROFIT_FEE_BPS = 2_500; // 25%

    address public immutable registry;
    address[] public allCubes;

    event CubeCreated(
        address indexed cube,
        address indexed creator,
        string name,
        string imageURI,
        address[] tokens,
        uint256[] weights,
        uint256 entryFeeBps,
        uint256 profitFeeBps
    );

    constructor(address registry_) {
        registry = registry_;
    }

    function createCube(
        string calldata name,
        string calldata symbol,
        string calldata imageURI,
        address[] calldata tokens,
        uint256[] calldata weights,
        uint256 entryFeeBps,
        uint256 profitFeeBps
    ) external returns (address cube) {
        uint256 n = tokens.length;
        require(n > 0 && n <= MAX_STOCKS, "1-5 stocks");
        require(weights.length == n, "length");
        require(entryFeeBps <= MAX_ENTRY_FEE_BPS && profitFeeBps <= MAX_PROFIT_FEE_BPS, "fee cap");

        uint256 sum;
        for (uint256 i; i < n; ++i) {
            require(IRegistry(registry).feedOf(tokens[i]) != address(0), "not listed");
            require(weights[i] > 0, "zero weight");
            for (uint256 j; j < i; ++j) require(tokens[j] != tokens[i], "duplicate");
            sum += weights[i];
        }
        require(sum == 10_000, "weights != 100%");

        cube = address(new Cube(name, symbol, imageURI, msg.sender, registry, tokens, weights, entryFeeBps, profitFeeBps));
        allCubes.push(cube);
        emit CubeCreated(cube, msg.sender, name, imageURI, tokens, weights, entryFeeBps, profitFeeBps);
    }

    function cubesCount() external view returns (uint256) {
        return allCubes.length;
    }

    function getCubes() external view returns (address[] memory) {
        return allCubes;
    }
}
