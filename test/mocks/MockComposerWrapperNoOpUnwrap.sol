// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDStockWrapperLike} from "../../src/DStockComposerRouter.sol";

/// @dev Wrapper mock whose `unwrap` does NOT move underlying and does NOT burn shares.
/// This allows testing the router's `unwrap_zero_out` branch while still being able to refund shares.
contract MockComposerWrapperNoOpUnwrap is ERC20, IDStockWrapperLike {
    mapping(address => uint8) public underlyingDecimals;

    constructor() ERC20("MockWrapperNoOp", "mNOOP") {}

    function setUnderlyingDecimals(address underlying, uint8 decimals_) external {
        underlyingDecimals[underlying] = decimals_;
    }

    function mintShares(address to, uint256 amount18) external {
        _mint(to, amount18);
    }

    function wrap(address token, uint256 amount, address to) external returns (uint256 net18, uint256 mintedShares) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull_underlying_failed");

        uint8 uDec = underlyingDecimals[token];
        require(uDec > 0 && uDec <= 18, "bad_underlying_decimals");

        net18 = amount * (10 ** (18 - uDec));
        mintedShares = net18;
        _mint(to, net18);
    }

    function unwrap(address /*token*/, uint256 /*amount18*/, address /*to*/) external {
        // intentionally no-op
    }
}

