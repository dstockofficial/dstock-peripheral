// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal WETH9/WBNB interface for wrapping/unwrapping native gas token.
interface IWrappedNativeLike {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/**
 * @title WrappedNativePayoutHelper
 * @notice Helper contract for delivering native gas token (BNB/ETH) when the router's reverse path unwraps into WBNB/WETH.
 *
 * @dev Why this helper exists:
 * - Standard WETH9/WBNB `withdraw()` typically performs `msg.sender.transfer(wad)` (2300 gas stipend).
 * - `DStockComposerRouter` is usually deployed behind an `ERC1967Proxy`, so receiving ETH/BNB via `transfer`
 *   can fail (proxy fallback/receive path may exceed 2300 gas).
 * - This helper is a small, non-proxy contract with a cheap `receive()` function, so it can safely be the
 *   `msg.sender` for `withdraw()` and then forward native to the final receiver using `call`.
 *
 * Flow (called by router):
 * 1) Router transfers `amount` of wrapped native (WBNB/WETH) to this helper.
 * 2) Helper calls `wrappedNative.withdraw(amount)` => receives native on `receive()`.
 * 3) Helper forwards native to `receiver` using `call`.
 * 4) If `receiver` rejects native, helper re-wraps (`deposit`) and refunds wrapped token to `refundBsc`.
 *
 * The helper is stateless and permissionless; router should store its address and call it as needed.
 */
contract WrappedNativePayoutHelper {
    error NotRouter();
    error ZeroRouter();

    address public immutable router;

    constructor(address _router) {
        if (_router == address(0)) revert ZeroRouter();
        router = _router;
    }

    modifier onlyRouter() {
        if (msg.sender != router) revert NotRouter();
        _;
    }

    /// @notice Unwrap `amount` of `wrappedNative` into native and send to `receiver`.
    /// @dev Assumes this helper already holds `amount` of `wrappedNative`.
    /// @return ok True if native was delivered to `receiver`. False if refund path was taken.
    function unwrapAndPayout(
        address wrappedNative,
        address receiver,
        address refundBsc,
        uint256 amount
    ) external onlyRouter returns (bool ok) {
        // 1) unwrap into native on this helper
        try IWrappedNativeLike(wrappedNative).withdraw(amount) {} catch {
            _tryTransfer(wrappedNative, refundBsc, amount);
            return false;
        }

        // 2) forward native to receiver
        (ok, ) = receiver.call{value: amount}("");
        if (ok) return true;

        // 3) receiver rejected native: re-wrap and refund as wrapped token
        try IWrappedNativeLike(wrappedNative).deposit{value: amount}() {} catch {
            // If re-wrapping fails, best-effort native refund to refundBsc.
            (bool ok2, ) = refundBsc.call{value: amount}("");
            ok2;
            return false;
        }

        _tryTransfer(wrappedNative, refundBsc, amount);
        return false;
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success) return false;
        if (data.length == 0) return true;
        return abi.decode(data, (bool));
    }

    receive() external payable {}
}

