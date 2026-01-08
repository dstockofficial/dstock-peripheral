// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {DStockUnwrapComposer} from "../src/DStockUnwrapComposer.sol";

/// @notice Deploys the DStockUnwrapComposer contract.
contract DeployUnwrapComposer is Script {
  function run() external {
    uint256 adminPk = vm.envUint("ADMIN_PK");
    address wrapper = vm.envAddress("WRAPPER_ADDRESS");
    address underlying = vm.envAddress("UNDERLYING_ADDRESS");
    address oftAdapter = vm.envAddress("OFT_ADAPTER_ADDRESS");

    vm.startBroadcast(adminPk);
    DStockUnwrapComposer composer = new DStockUnwrapComposer(wrapper, underlying, oftAdapter);
    vm.stopBroadcast();

    console2.log("DStockUnwrapComposer:", address(composer));
    console2.log("Wrapper:", wrapper);
    console2.log("Underlying:", underlying);
    console2.log("OFTAdapter:", oftAdapter);
  }
}
