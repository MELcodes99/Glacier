// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StockRegistry
/// @notice Allowlist of Base B20 stock tokens that Cubes may hold, each paired
///         with its Chainlink tokenized-equity feed (token price, multiplier included).
contract StockRegistry is Ownable {
    mapping(address token => address feed) public feedOf;
    address[] public listed;

    event StockSet(address indexed token, address indexed feed);

    constructor(address owner_) Ownable(owner_) {}

    function setStock(address token, address feed) external onlyOwner {
        require(token != address(0), "zero token");
        if (feedOf[token] == address(0) && feed != address(0)) listed.push(token);
        feedOf[token] = feed;
        emit StockSet(token, feed);
    }

    function isListed(address token) external view returns (bool) {
        return feedOf[token] != address(0);
    }

    function listedTokens() external view returns (address[] memory) {
        return listed;
    }
}
