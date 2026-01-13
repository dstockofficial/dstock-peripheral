// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDStockWrapperLike} from "../../src/DStockComposerRouter.sol";

/// @dev Simple wrapper/share token for ComposerRouter tests.
/// - `wrap`: pulls underlying from caller, mints shares (18 decimals) 1:1 scaled to 18.
/// - `unwrap`: burns shares from caller, transfers underlying from wrapper balance to `to`.
contract MockComposerWrapper is ERC20, IDStockWrapperLike {
    mapping(address => uint8) public underlyingDecimals;

    constructor() ERC20("MockWrapperShare", "mSHARE") {}

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

    function unwrap(address token, uint256 amount18, address to) external {
        uint8 uDec = underlyingDecimals[token];
        require(uDec > 0 && uDec <= 18, "bad_underlying_decimals");

        _burn(msg.sender, amount18);

        uint256 amountToken = amount18 / (10 ** (18 - uDec));
        require(IERC20(token).transfer(to, amountToken), "push_underlying_failed");
    }

    function previewWrap(address token, uint256 amount) external view returns (uint256 net18, uint256 fee) {
        uint8 uDec = underlyingDecimals[token];
        if (uDec == 0 || uDec > 18) return (0, 0);
        net18 = amount * (10 ** (18 - uDec));
        return (net18, 0);
    }
}

