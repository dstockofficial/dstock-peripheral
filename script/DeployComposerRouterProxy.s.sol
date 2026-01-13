// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DStockComposerRouter} from "../src/DStockComposerRouter.sol";

/// @notice Deploys the UUPS implementation + ERC1967Proxy for DStockComposerRouter and optionally registers one asset.
contract DeployComposerRouterProxy is Script {
    function run() external {
        uint256 adminPk = vm.envUint("ADMIN_PK");

        address endpoint = vm.envAddress("ENDPOINT_ADDRESS");
        address owner = vm.envAddress("OWNER_ADDRESS");

        // optional: initial asset registration
        address underlyingOft = vm.envOr("UNDERLYING_OFT_ADDRESS", address(0));
        address wrapper = vm.envOr("WRAPPER_ADDRESS", address(0));
        address shareAdapter = vm.envOr("SHARE_ADAPTER_ADDRESS", address(0));
        uint256 sharedDecimals = vm.envOr("SHARED_DECIMALS", uint256(0));

        vm.startBroadcast(adminPk);

        // 1) deploy implementation
        DStockComposerRouter impl = new DStockComposerRouter();

        // 2) deploy proxy + initialize
        bytes memory initData = abi.encodeCall(DStockComposerRouter.initialize, (endpoint, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // 3) optional: register one asset
        if (underlyingOft != address(0) && wrapper != address(0) && shareAdapter != address(0)) {
            DStockComposerRouter(payable(address(proxy))).addAsset(
                underlyingOft,
                wrapper,
                shareAdapter,
                uint8(sharedDecimals)
            );
        }

        vm.stopBroadcast();

        console2.log("DStockComposerRouter implementation:", address(impl));
        console2.log("DStockComposerRouter proxy:", address(proxy));
        console2.log("Endpoint:", endpoint);
        console2.log("Owner:", owner);
        if (underlyingOft != address(0)) {
            console2.log("Initial underlyingOft:", underlyingOft);
            console2.log("Initial wrapper:", wrapper);
            console2.log("Initial shareAdapter:", shareAdapter);
            console2.log("sharedDecimals:", sharedDecimals);
        }
    }
}

