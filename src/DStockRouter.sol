// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IDStockWrapper} from "./interfaces/IDStockWrapper.sol";
import {IOFTAdapter} from "./interfaces/IOFTAdapter.sol";

/// @title DStockRouter
/// @notice One-click Underlying -> DStock -> HyperEVM bridge on BSC.
contract DStockRouter is ReentrancyGuard {
  using SafeERC20 for IERC20;

  IDStockWrapper public immutable wrapper;
  IOFTAdapter public immutable oftAdapter;
  IERC20 public immutable dstockToken;

  event WrapAndBridge(
    address indexed sender,
    address indexed underlying,
    uint256 amountIn,
    uint256 amountSentLD,
    uint32 dstEid,
    bytes32 to
  );

  error ZeroAddress();
  error AmountZero();
  error UnsupportedUnderlying(address token);
  error InvalidRecipient();
  error InsufficientFee(uint256 provided, uint256 required);
  error RefundFailed();
  error TokenCallFailed();
  error TokenOperationFailed();

  constructor(address _wrapper, address _oftAdapter) {
    if (_wrapper == address(0) || _oftAdapter == address(0)) revert ZeroAddress();
    wrapper = IDStockWrapper(_wrapper);
    oftAdapter = IOFTAdapter(_oftAdapter);
    dstockToken = IERC20(_wrapper);
  }

  /// @notice Wrap Underlying into DStock and bridge to HyperEVM via LayerZero.
  /// @param underlying Underlying token address on BSC.
  /// @param amount Amount of underlying in its native decimals.
  /// @param dstEid Destination LayerZero EID (HyperEVM mainnet: 30367).
  /// @param to Recipient on destination chain (bytes32-encoded).
  /// @param extraOptions LayerZero options (can be empty).
  function wrapAndBridge(
    address underlying,
    uint256 amount,
    uint32 dstEid,
    bytes32 to,
    bytes calldata extraOptions
  ) external payable nonReentrant returns (uint256 amountSentLD) {
    return _wrapAndBridge(underlying, amount, dstEid, to, extraOptions);
  }

  /// @notice Quote the LayerZero fee for wrap + bridge.
  function quoteWrapAndBridge(
    address underlying,
    uint256 amount,
    uint32 dstEid,
    bytes32 to,
    bytes calldata extraOptions
  ) external view returns (uint256 nativeFee) {
    return _quoteWrapAndBridge(underlying, amount, dstEid, to, extraOptions);
  }

  function _wrapAndBridge(
    address underlying,
    uint256 amount,
    uint32 dstEid,
    bytes32 to,
    bytes calldata extraOptions
  ) internal returns (uint256 amountSentLD) {
    if (amount == 0) revert AmountZero();
    if (to == bytes32(0)) revert InvalidRecipient();
    if (!wrapper.isUnderlyingEnabled(underlying)) revert UnsupportedUnderlying(underlying);

    // Pull underlying from user
    IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);

    // Approve wrapper to pull underlying
    _forceApprove(IERC20(underlying), address(wrapper), amount);

    // Wrap into DStock (18 decimals)
    (uint256 net18, ) = wrapper.wrap(underlying, amount, address(this));
    amountSentLD = net18;

    // Approve adapter to lock DStock
    _forceApprove(dstockToken, address(oftAdapter), net18);

    IOFTAdapter.SendParam memory sendParam = IOFTAdapter.SendParam({
      dstEid: dstEid,
      to: to,
      amountLD: net18,
      minAmountLD: net18,
      extraOptions: extraOptions,
      composeMsg: "",
      oftCmd: ""
    });

    IOFTAdapter.MessagingFee memory fee = oftAdapter.quoteSend(sendParam, false);
    if (msg.value < fee.nativeFee) revert InsufficientFee(msg.value, fee.nativeFee);

    oftAdapter.send{value: fee.nativeFee}(sendParam, fee, msg.sender);

    uint256 refund = msg.value - fee.nativeFee;
    if (refund > 0) {
      (bool ok, ) = msg.sender.call{value: refund}("");
      if (!ok) revert RefundFailed();
    }

    emit WrapAndBridge(msg.sender, underlying, amount, amountSentLD, dstEid, to);
  }

  function _quoteWrapAndBridge(
    address underlying,
    uint256 amount,
    uint32 dstEid,
    bytes32 to,
    bytes calldata extraOptions
  ) internal view returns (uint256 nativeFee) {
    if (amount == 0) revert AmountZero();
    if (to == bytes32(0)) revert InvalidRecipient();
    if (!wrapper.isUnderlyingEnabled(underlying)) revert UnsupportedUnderlying(underlying);

    (uint256 estimatedNet18, ) = wrapper.previewWrap(underlying, amount);
    if (estimatedNet18 == 0) revert AmountZero();

    IOFTAdapter.SendParam memory sendParam = IOFTAdapter.SendParam({
      dstEid: dstEid,
      to: to,
      amountLD: estimatedNet18,
      minAmountLD: estimatedNet18,
      extraOptions: extraOptions,
      composeMsg: "",
      oftCmd: ""
    });

    IOFTAdapter.MessagingFee memory fee = oftAdapter.quoteSend(sendParam, false);
    return fee.nativeFee;
  }

  function _forceApprove(IERC20 token, address spender, uint256 amount) internal {
    uint256 current = token.allowance(address(this), spender);
    if (current >= amount) return;

    if (current != 0) {
      _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, 0));
    }
    _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, amount));
  }

  function _callOptionalReturn(IERC20 token, bytes memory data) private {
    (bool success, bytes memory returndata) = address(token).call(data);
    if (!success) revert TokenCallFailed();
    if (returndata.length > 0 && !abi.decode(returndata, (bool))) {
      revert TokenOperationFailed();
    }
  }
}
