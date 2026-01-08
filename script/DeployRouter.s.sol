// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {DStockRouter} from "../src/DStockRouter.sol";

/// @notice Deploys the DStockRouter contract.
contract DeployRouter is Script {
  function run() external {
    uint256 adminPk = vm.envUint("ADMIN_PK");
    address wrapper = vm.envAddress("WRAPPER_ADDRESS");
    address oftAdapter = vm.envAddress("OFT_ADAPTER_ADDRESS");

    vm.startBroadcast(adminPk);
    DStockRouter router = new DStockRouter(wrapper, oftAdapter);
    vm.stopBroadcast();

    console2.log("DStockRouter:", address(router));
    console2.log("Wrapper:", wrapper);
    console2.log("OFTAdapter:", oftAdapter);
  }
}
