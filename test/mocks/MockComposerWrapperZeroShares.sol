// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDStockWrapperLike} from "../../src/DStockComposerRouter.sol";

/// @dev Wrapper that consumes underlying on wrap but mints 0 shares.
/// Used to test router behavior when `sharesOut == 0` but underlying was already pulled.
contract MockComposerWrapperZeroShares is ERC20, IDStockWrapperLike {
    constructor() ERC20("ZeroShares", "ZSHARE") {}

    function wrap(address token, uint256 amount, address /*to*/ ) external returns (uint256 net18, uint256 mintedShares) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "pull_underlying_failed");
        return (0, 0);
    }

    function unwrap(address /*token*/ , uint256 /*amount*/ , address /*to*/ ) external {}
}

