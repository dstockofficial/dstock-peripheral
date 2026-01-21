// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DStockComposerRouterV2} from "../src/DStockComposerRouter.sol";
import {WrappedNativePayoutHelperV2} from "../src/WrappedNativePayoutHelper.sol";

/// @notice Deploys the UUPS implementation + ERC1967Proxy for DStockComposerRouterV2 and optionally registers routes.
///
/// Env vars:
/// - Required:
///   - ADMIN_PK
///   - ENDPOINT_ADDRESS
///   - CHAIN_EID
///   - OWNER_ADDRESS (initial ADMIN_ROLE address)
/// - Optional (initial route config):
///   - WRAPPER_ADDRESS
///   - SHARE_ADAPTER_ADDRESS
///   - UNDERLYING_ADDRESS (single underlying token)
///   - UNDERLYING_ADDRESSES (comma-separated list, overrides UNDERLYING_ADDRESS)
/// - Optional (wrapped native support):
///   - WRAPPED_NATIVE_ADDRESS (e.g., WBNB/WETH on this chain)
///   - WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS (if unset and WRAPPED_NATIVE_ADDRESS is set, script deploys a helper)
contract DeployComposerRouterProxy is Script {
    function run() external {
        uint256 adminPk = vm.envUint("ADMIN_PK");

        address endpoint = vm.envAddress("ENDPOINT_ADDRESS");
        uint32 chainEid = uint32(vm.envUint("CHAIN_EID"));
        address owner = vm.envAddress("OWNER_ADDRESS");

        // optional: initial route registration
        address wrapper = vm.envOr("WRAPPER_ADDRESS", address(0));
        address shareAdapter = vm.envOr("SHARE_ADAPTER_ADDRESS", address(0));
        address underlying = vm.envOr("UNDERLYING_ADDRESS", address(0));
        string memory underlyingsCsv = vm.envOr("UNDERLYING_ADDRESSES", string(""));
        address wrappedNative = vm.envOr("WRAPPED_NATIVE_ADDRESS", address(0));
        address wrappedNativeHelper = vm.envOr("WRAPPED_NATIVE_PAYOUT_HELPER_ADDRESS", address(0));

        vm.startBroadcast(adminPk);

        // 1) deploy implementation
        DStockComposerRouterV2 impl = new DStockComposerRouterV2();

        // 2) deploy proxy + initialize
        bytes memory initData = abi.encodeCall(DStockComposerRouterV2.initialize, (endpoint, chainEid, owner));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

        // 3) optional: configure routes / wrapped native
        if (wrapper != address(0) && shareAdapter != address(0)) {
            DStockComposerRouterV2 router = DStockComposerRouterV2(payable(address(proxy)));

            // Always register reverse mapping (shareAdapter -> wrapper).
            // If no underlying is provided, this still enables reverse compose routing.
            router.setRouteConfig(address(0), wrapper, shareAdapter);

            // Register one or more underlyings for forward routing.
            // - If UNDERLYING_ADDRESSES is set (non-empty), it overrides UNDERLYING_ADDRESS.
            // - Format: "0xabc...,0xdef...,0x123..."
            if (bytes(underlyingsCsv).length > 0) {
                address[] memory list = _parseAddressCsv(underlyingsCsv);
                for (uint256 i = 0; i < list.length; i++) {
                    if (list[i] == address(0)) continue;
                    router.setRouteConfig(list[i], wrapper, shareAdapter);
                }
            } else if (underlying != address(0)) {
                router.setRouteConfig(underlying, wrapper, shareAdapter);
            }

            // Optional: enable native entry + reverse-local native delivery via wrapped native token.
            // - Requires WRAPPED_NATIVE_ADDRESS (WBNB/WETH on this chain)
            // - For wrapAndBridgeNative: also registers wrappedNative as an underlying route for the same (wrapper, shareAdapter)
            if (wrappedNative != address(0)) {
                router.setWrappedNative(wrappedNative);

                // If helper isn't provided, deploy one now.
                if (wrappedNativeHelper == address(0)) {
                    WrappedNativePayoutHelperV2 helper = new WrappedNativePayoutHelperV2(address(proxy));
                    wrappedNativeHelper = address(helper);
                }
                router.setWrappedNativePayoutHelper(wrappedNativeHelper);

                // Needed for `wrapAndBridgeNative` (so router can map wrappedNative -> (wrapper, shareAdapter)).
                router.setRouteConfig(wrappedNative, wrapper, shareAdapter);
            }
        }

        vm.stopBroadcast();

        console2.log("DStockComposerRouter implementation:", address(impl));
        console2.log("DStockComposerRouter proxy:", address(proxy));
        console2.log("Endpoint:", endpoint);
        console2.log("ChainEid:", chainEid);
        console2.log("Owner:", owner);
        if (wrapper != address(0) && shareAdapter != address(0)) {
            console2.log("Initial wrapper:", wrapper);
            console2.log("Initial shareAdapter:", shareAdapter);
            if (bytes(underlyingsCsv).length > 0) {
                console2.log("Initial underlyings (csv):", underlyingsCsv);
            } else if (underlying != address(0)) {
                console2.log("Initial underlying:", underlying);
            }
            if (wrappedNative != address(0)) {
                console2.log("Wrapped native:", wrappedNative);
                console2.log("Wrapped native payout helper:", wrappedNativeHelper);
            }
        }
    }

    function _parseAddressCsv(string memory csv) internal view returns (address[] memory) {
        bytes memory b = bytes(csv);

        // Count commas to size the array.
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == bytes1(",")) count++;
        }
        address[] memory out = new address[](count);

        uint256 start = 0;
        uint256 idx = 0;
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == bytes1(",")) {
                string memory part = _trim(_slice(csv, start, i));
                if (bytes(part).length > 0) {
                    out[idx] = vm.parseAddress(part);
                }
                idx++;
                start = i + 1;
            }
        }
        return out;
    }

    function _slice(string memory s, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (end <= start) return "";
        bytes memory out = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = b[i];
        }
        return string(out);
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 start = 0;
        uint256 end = b.length;
        while (start < end && (b[start] == 0x20 || b[start] == 0x09 || b[start] == 0x0A || b[start] == 0x0D)) start++;
        while (end > start && (b[end - 1] == 0x20 || b[end - 1] == 0x09 || b[end - 1] == 0x0A || b[end - 1] == 0x0D)) end--;
        return _slice(s, start, end);
    }
}

