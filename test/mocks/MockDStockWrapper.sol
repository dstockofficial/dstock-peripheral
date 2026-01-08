// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";
import {IDStockWrapper} from "../../src/interfaces/IDStockWrapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockDStockWrapper is MockERC20, IDStockWrapper {
    mapping(address => bool) public enabledUnderlyings;
    mapping(address => uint8) public underlyingDecimals;
    
    constructor() MockERC20("DStock Mock", "dMOCK", 18) {}

    function setUnderlying(address underlying, bool enabled, uint8 decimals_) external {
        enabledUnderlyings[underlying] = enabled;
        underlyingDecimals[underlying] = decimals_;
    }

    // --- Interface Implementation ---

    function initialize(InitParams calldata) external {}
    function setPausedByFactory(bool) external {}
    function factoryRegistry() external view returns (address) { return address(0); }
    function addUnderlying(address) external {}
    function setUnderlyingEnabled(address token, bool enabled) external {
        enabledUnderlyings[token] = enabled;
    }

    function isUnderlyingEnabled(address underlying) external view returns (bool) {
        return enabledUnderlyings[underlying];
    }

    function underlyingInfo(address underlying) external view returns (bool enabled, uint8 decimals_, uint256 liquidToken) {
        return (enabledUnderlyings[underlying], underlyingDecimals[underlying], 0);
    }

    function listUnderlyings() external view returns (address[] memory) {
        return new address[](0);
    }

    function wrap(address underlying, uint256 amount, address to) external returns (uint256 net18, uint256 shares) {
        // Pull underlying from sender (router) to this wrapper
        IERC20(underlying).transferFrom(msg.sender, address(this), amount);

        uint8 uDec = underlyingDecimals[underlying];
        net18 = amount * (10 ** (18 - uDec)); 
        shares = net18; // 1:1 shares
        
        _mint(to, net18);
        return (net18, shares);
    }

    function previewWrap(address underlying, uint256 amount) external view returns (uint256 net18, uint256 fee) {
        uint8 uDec = underlyingDecimals[underlying];
        if (uDec == 0) return (0, 0); 
        net18 = amount * (10 ** (18 - uDec));
        return (net18, 0);
    }

    function unwrap(address underlying, uint256 amount, address /*to*/) external {
        _burn(msg.sender, amount);
        // No return value in interface
    }
}
