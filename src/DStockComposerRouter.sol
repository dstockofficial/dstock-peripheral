// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal LayerZero OFT compose message decoder.
/// Compose payload format:
/// nonce(8) | srcEid(4) | amountLD(32) | composeFrom(32) | composeMsg(bytes)
library OFTComposeMsgCodecLite {
    uint256 private constant AMOUNT_LD_START = 12; // 8 + 4
    uint256 private constant AMOUNT_LD_END = 44; // 12 + 32
    uint256 private constant COMPOSE_MSG_START = 76; // 8 + 4 + 32 + 32

    function amountLD(bytes calldata _msg) internal pure returns (uint256) {
        if (_msg.length < AMOUNT_LD_END) return 0;
        return uint256(bytes32(_msg[AMOUNT_LD_START:AMOUNT_LD_END]));
    }

    function composeMsg(bytes calldata _msg) internal pure returns (bytes memory) {
        if (_msg.length <= COMPOSE_MSG_START) return bytes("");
        return _msg[COMPOSE_MSG_START:];
    }
}

/**
 * @dev Minimal interface for an OFT (EVM) token used for routing.
 */
interface IOFTLike {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view returns (MessagingFee memory);

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    )
        external
        payable
        returns (
            bytes32 guid,
            uint64 nonce,
            MessagingFee memory fee,
            uint256 amountSentLD,
            uint256 amountReceivedLD
        );
}

/**
 * @dev DStockWrapper interface we rely on.
 */
interface IDStockWrapperLike {
    function wrap(address token, uint256 amount, address to) external returns (uint256 net18, uint256 mintedShares);
    function unwrap(address token, uint256 amount, address to) external;
}

/// @dev Optional wrapper view interface (used for fee quoting on user wraps).
interface IDStockWrapperPreview {
    function previewWrap(address token, uint256 amount) external view returns (uint256 net18, uint256 fee);
}

/**
 * @dev LayerZero v2 compose interface (executor calls this via EndpointV2).
 */
interface IOAppComposer {
    function lzCompose(
        address _oApp,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

/**
 * @title DStockComposerRouter
 * @notice UUPS-upgradeable, multi-asset LayerZero compose-driven two-hop router on BSC.
 *
 * - Forward: receives `underlying` (credited on lzReceive) -> wraps into `wrapper` shares -> sends shares via `shareAdapter`.
 * - Reverse: receives wrapper shares via `shareAdapter` -> unwraps into `underlying` -> sends underlying to the final chain.
 *
 * Key safety properties:
 * - GUID idempotency (processedGuids)
 * - Pause does not revert compose (refund + return)
 * - Failures do not revert compose (refund + return); funds can be rescued if refund fails
 */
contract DStockComposerRouter is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IOAppComposer
{
    using OFTComposeMsgCodecLite for bytes;
    using SafeERC20 for IERC20;

    /// @notice BSC EndpointV2 address
    address public endpoint;

    /// @notice The LayerZero endpoint ID (eid) of the chain this router is deployed on.
    uint32 public chainEid;

    /// @notice underlying token (either OFT or local ERC20) -> wrapper (shares token + wrap/unwrap interface).
    mapping(address => address) public underlyingToWrapper;

    /// @notice underlying token (either OFT or local ERC20) -> shareAdapter (OFT adapter for shares to HyperEVM).
    mapping(address => address) public underlyingToShareAdapter;

    /// @notice shareAdapter -> wrapper.
    mapping(address => address) public shareAdapterToWrapper;

    mapping(bytes32 => bool) public processedGuids;

    uint256[50] private __gap;

    event UnderlyingConfigSet(address indexed underlying, address indexed wrapper, address indexed shareAdapter);
    event ShareAdapterWrapperSet(address indexed shareAdapter, address indexed wrapper);

    event WrappedAndForwarded(bytes32 indexed guid, uint32 finalDstEid, bytes32 finalTo, uint256 underlyingIn, uint256 sharesOut);
    event UnwrappedAndForwarded(bytes32 indexed guid, uint32 finalDstEid, bytes32 finalTo, uint256 sharesIn, uint256 underlyingOut);
    event RouteFailed(bytes32 indexed guid, string reason, address refundBsc, uint256 amountLD);
    event RefundFailed(bytes32 indexed guid, address indexed token, address indexed refundBsc, uint256 amount);

    error ZeroAddress();
    error NotEndpoint();
    error InvalidOApp();
    error InvalidRefundAddress();
    error AmountZero();
    error InvalidRecipient();
    error InsufficientFee(uint256 provided, uint256 required);
    error RefundFailedNative();

    struct RouteMsg {
        uint32 finalDstEid;
        bytes32 finalTo;
        address refundBsc;
        uint256 minAmountLD2;
    }

    struct ReverseRouteMsg {
        address underlying;
        uint32 finalDstEid;
        bytes32 finalTo;
        address refundBsc;
        uint16 unwrapBps;
        uint256 minAmountLD2;
        bytes extraOptions2;
        bytes composeMsg2;
    }

    function initialize(address _endpoint, uint32 _chainEid, address _owner) external initializer {
        if (_endpoint == address(0) || _owner == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        endpoint = _endpoint;
        chainEid = _chainEid;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}


    /// @notice Configure routing mappings in one call.
    /// @dev Always registers the reverse mapping `shareAdapter -> wrapper`.
    /// If `underlying != address(0)`, also registers forward mappings `underlying -> (wrapper, shareAdapter)`.
    function setRouteConfig(address underlying, address wrapper, address shareAdapter) public onlyOwner {
        if (wrapper == address(0) || shareAdapter == address(0)) revert ZeroAddress();

        shareAdapterToWrapper[shareAdapter] = wrapper;
        emit ShareAdapterWrapperSet(shareAdapter, wrapper);

        if (underlying != address(0)) {
            underlyingToWrapper[underlying] = wrapper;
            underlyingToShareAdapter[underlying] = shareAdapter;
            emit UnderlyingConfigSet(underlying, wrapper, shareAdapter);
        }
    }

    /// @notice User entry: wrap an underlying token into wrapper shares and bridge shares via shareAdapter.
    /// @dev Uses the same registry as compose-forward; `underlying` can be an OFT token or a local ERC20.
    function wrapAndBridge(
        address underlying,
        uint256 amount,
        uint32 dstEid,
        bytes32 to,
        bytes calldata extraOptions
    ) external payable nonReentrant returns (uint256 amountSentLD) {
        if (amount == 0) revert AmountZero();
        if (to == bytes32(0)) revert InvalidRecipient();

        address wrapper = underlyingToWrapper[underlying];
        address shareAdapter = underlyingToShareAdapter[underlying];
        if (wrapper == address(0) || shareAdapter == address(0)) revert InvalidOApp();

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(underlying).forceApprove(wrapper, amount);

        (uint256 net18, ) = IDStockWrapperLike(wrapper).wrap(underlying, amount, address(this));
        amountSentLD = net18;
        if (amountSentLD == 0) revert AmountZero();

        IERC20(wrapper).forceApprove(shareAdapter, amountSentLD);

        IOFTLike.SendParam memory sp = IOFTLike.SendParam({
            dstEid: dstEid,
            to: to,
            amountLD: amountSentLD,
            minAmountLD: amountSentLD,
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
        });

        IOFTLike.MessagingFee memory fee = IOFTLike(shareAdapter).quoteSend(sp, false);
        if (msg.value < fee.nativeFee) revert InsufficientFee(msg.value, fee.nativeFee);

        IOFTLike(shareAdapter).send{value: fee.nativeFee}(sp, fee, msg.sender);

        uint256 refund = msg.value - fee.nativeFee;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailedNative();
        }
    }

    /// @notice Quote the LayerZero fee for user wrap + bridge.
    /// @dev Requires wrapper to implement `previewWrap`.
    function quoteWrapAndBridge(
        address underlying,
        uint256 amount,
        uint32 dstEid,
        bytes32 to,
        bytes calldata extraOptions
    ) external view returns (uint256 nativeFee) {
        if (amount == 0) revert AmountZero();
        if (to == bytes32(0)) revert InvalidRecipient();

        address wrapper = underlyingToWrapper[underlying];
        address shareAdapter = underlyingToShareAdapter[underlying];
        if (wrapper == address(0) || shareAdapter == address(0)) revert InvalidOApp();

        (uint256 estimatedNet18, ) = IDStockWrapperPreview(wrapper).previewWrap(underlying, amount);
        if (estimatedNet18 == 0) revert AmountZero();

        IOFTLike.SendParam memory sp = IOFTLike.SendParam({
            dstEid: dstEid,
            to: to,
            amountLD: estimatedNet18,
            minAmountLD: estimatedNet18,
            extraOptions: extraOptions,
            composeMsg: "",
            oftCmd: ""
        });

        IOFTLike.MessagingFee memory fee = IOFTLike(shareAdapter).quoteSend(sp, false);
        return fee.nativeFee;
    }

    function lzCompose(
        address _oApp,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable nonReentrant {
        if (msg.sender != endpoint) revert NotEndpoint();
        if (processedGuids[_guid]) return;
        processedGuids[_guid] = true;

        bytes memory inner = _message.composeMsg();
        uint256 amountLD = _message.amountLD();

        // Reverse: _oApp is a supported shareAdapter
        address wrapper = shareAdapterToWrapper[_oApp];
        if (wrapper != address(0)) {
            _lzComposeReverse(wrapper, _guid, amountLD, inner);
            return;
        }

        // Forward: _oApp is the underlying token (OFT or local ERC20) that was credited to this router
        address shareAdapter = underlyingToShareAdapter[_oApp];
        wrapper = underlyingToWrapper[_oApp];
        if (wrapper == address(0) || shareAdapter == address(0)) revert InvalidOApp();

        _lzComposeForward(_oApp, wrapper, shareAdapter, _guid, amountLD, inner);
    }

    function _lzComposeForward(
        address underlying,
        address wrapper,
        address shareAdapter,
        bytes32 guid,
        uint256 underlyingAmount,
        bytes memory inner
    ) internal {
        RouteMsg memory r;
        try this._decodeRouteMsg(inner) returns (RouteMsg memory rr) {
            r = rr;
        } catch {
            _fail(guid, "decode_route_failed", address(0), underlyingAmount);
            return;
        }
        if (r.refundBsc == address(0)) {
            _fail(guid, "refund_zero", address(0), underlyingAmount);
            return;
        }

        uint256 sharesOut = _wrapUnderlying(wrapper, underlying, guid, underlyingAmount, r.refundBsc);
        if (sharesOut == 0) return;

        bool ok = _sendShares(wrapper, shareAdapter, guid, underlyingAmount, sharesOut, r.finalDstEid, r.finalTo, r.refundBsc, r.minAmountLD2);
        if (!ok) return;

        _refundNative(r.refundBsc);
    }

    function _lzComposeReverse(address wrapper, bytes32 guid, uint256 sharesIn, bytes memory inner) internal {
        ReverseRouteMsg memory r;
        try this._decodeReverseRouteMsg(inner) returns (ReverseRouteMsg memory rr) {
            r = rr;
        } catch {
            _fail(guid, "decode_reverse_route_failed", address(0), sharesIn);
            return;
        }
        if (r.refundBsc == address(0)) {
            _fail(guid, "refund_zero", address(0), sharesIn);
            return;
        }
        if (r.underlying == address(0)) {
            _refundToken(wrapper, guid, "underlying_zero", r.refundBsc, sharesIn);
            return;
        }
        if (r.unwrapBps == 0 || r.unwrapBps > 10_000) {
            _refundToken(wrapper, guid, "bad_unwrap_bps", r.refundBsc, sharesIn);
            return;
        }

        uint256 underlyingOut = _unwrapShares(wrapper, r.underlying, guid, sharesIn, r.refundBsc, r.unwrapBps);
        if (underlyingOut == 0) return;

        if (r.finalDstEid == chainEid) {
            address receiver = address(uint160(uint256(r.finalTo)));
            if (receiver == address(0)) {
                _refundToken(r.underlying, guid, "receiver_zero", r.refundBsc, underlyingOut);
                return;
            }
            uint256 minUnderlying = r.minAmountLD2 == 0 ? underlyingOut : r.minAmountLD2;
            if (underlyingOut < minUnderlying) {
                _refundToken(r.underlying, guid, "underlying_below_min", r.refundBsc, underlyingOut);
                return;
            }
            bool okDeliver = _tryTransfer(r.underlying, receiver, underlyingOut);
            if (!okDeliver) {
                _refundToken(r.underlying, guid, "deliver_failed", r.refundBsc, underlyingOut);
                return;
            }
            emit UnwrappedAndForwarded(guid, r.finalDstEid, r.finalTo, sharesIn, underlyingOut);
        } else {
            bool ok2 = _sendUnderlyingToFinal(r.underlying, guid, sharesIn, underlyingOut, r);
            if (!ok2) return;
        }

        _refundNative(r.refundBsc);
    }

    function _wrapUnderlying(address wrapper, address underlying, bytes32 guid, uint256 underlyingAmount, address refundBsc)
        internal
        returns (uint256)
    {
        uint256 balUnderlying = IERC20(underlying).balanceOf(address(this));
        if (balUnderlying < underlyingAmount) {
            _refundToken(underlying, guid, "insufficient_underlying", refundBsc, underlyingAmount);
            return 0;
        }

        IERC20(underlying).forceApprove(wrapper, underlyingAmount);

        uint256 shareBalBefore = IERC20(wrapper).balanceOf(address(this));
        IDStockWrapperLike(wrapper).wrap(underlying, underlyingAmount, address(this));
        uint256 shareBalAfter = IERC20(wrapper).balanceOf(address(this));
        uint256 sharesOut = shareBalAfter - shareBalBefore;

        if (sharesOut == 0) {
            _refundToken(underlying, guid, "wrap_zero_shares", refundBsc, underlyingAmount);
            return 0;
        }
        return sharesOut;
    }

    function _sendShares(
        address wrapper,
        address shareAdapter,
        bytes32 guid,
        uint256 underlyingIn,
        uint256 sharesOut,
        uint32 finalDstEid,
        bytes32 finalTo,
        address refundBsc,
        uint256 minAmountLD2
    ) internal returns (bool) {
        uint256 minShares = minAmountLD2 == 0 ? sharesOut : minAmountLD2;

        IOFTLike.SendParam memory sp = IOFTLike.SendParam({
            dstEid: finalDstEid,
            to: finalTo,
            amountLD: sharesOut,
            minAmountLD: minShares,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        IOFTLike.MessagingFee memory fee2 = IOFTLike(shareAdapter).quoteSend(sp, false);
        if (address(this).balance < fee2.nativeFee) {
            _refundToken(wrapper, guid, "fee_insufficient", refundBsc, sharesOut);
            return false;
        }

        IERC20(wrapper).forceApprove(shareAdapter, sharesOut);

        try IOFTLike(shareAdapter).send{value: fee2.nativeFee}(sp, fee2, refundBsc) {
            emit WrappedAndForwarded(guid, finalDstEid, finalTo, underlyingIn, sharesOut);
            return true;
        } catch {
            _refundToken(wrapper, guid, "send2_failed", refundBsc, sharesOut);
            return false;
        }
    }

    function _decodeRouteMsg(bytes memory inner) external pure returns (RouteMsg memory) {
        return abi.decode(inner, (RouteMsg));
    }

    function _decodeReverseRouteMsg(bytes memory inner) external pure returns (ReverseRouteMsg memory) {
        return abi.decode(inner, (ReverseRouteMsg));
    }

    function _unwrapShares(address wrapper, address underlying, bytes32 guid, uint256 sharesIn, address refundBsc, uint16 unwrapBps)
        internal
        returns (uint256)
    {
        uint256 balShares = IERC20(wrapper).balanceOf(address(this));
        if (balShares < sharesIn) {
            _refundToken(wrapper, guid, "insufficient_shares", refundBsc, sharesIn);
            return 0;
        }

        uint256 attemptUnderlying = (sharesIn * uint256(unwrapBps)) / 10_000;
        if (attemptUnderlying == 0) {
            _refundToken(wrapper, guid, "unwrap_zero_amount", refundBsc, sharesIn);
            return 0;
        }

        uint256 underlyingBalBefore = IERC20(underlying).balanceOf(address(this));

        try IDStockWrapperLike(wrapper).unwrap(underlying, attemptUnderlying, address(this)) {} catch {
            _refundToken(wrapper, guid, "unwrap_failed", refundBsc, sharesIn);
            return 0;
        }

        uint256 underlyingBalAfter = IERC20(underlying).balanceOf(address(this));
        uint256 underlyingOut = underlyingBalAfter - underlyingBalBefore;
        if (underlyingOut == 0) {
            _refundToken(wrapper, guid, "unwrap_zero_out", refundBsc, sharesIn);
            return 0;
        }
        return underlyingOut;
    }

    function _sendUnderlyingToFinal(address underlying, bytes32 guid, uint256 sharesIn, uint256 underlyingOut, ReverseRouteMsg memory r)
        internal
        returns (bool)
    {
        uint256 minUnderlying = r.minAmountLD2 == 0 ? underlyingOut : r.minAmountLD2;
        if (underlyingOut < minUnderlying) {
            _refundToken(underlying, guid, "underlying_below_min", r.refundBsc, underlyingOut);
            return false;
        }

        IOFTLike.SendParam memory sp = IOFTLike.SendParam({
            dstEid: r.finalDstEid,
            to: r.finalTo,
            amountLD: underlyingOut,
            minAmountLD: minUnderlying,
            extraOptions: r.extraOptions2,
            composeMsg: r.composeMsg2,
            oftCmd: ""
        });

        IOFTLike.MessagingFee memory fee2 = IOFTLike(underlying).quoteSend(sp, false);
        if (address(this).balance < fee2.nativeFee) {
            _refundToken(underlying, guid, "fee_insufficient", r.refundBsc, underlyingOut);
            return false;
        }

        try IOFTLike(underlying).send{value: fee2.nativeFee}(sp, fee2, r.refundBsc) {
            emit UnwrappedAndForwarded(guid, r.finalDstEid, r.finalTo, sharesIn, underlyingOut);
            return true;
        } catch {
            _refundToken(underlying, guid, "send2_failed", r.refundBsc, underlyingOut);
            return false;
        }
    }
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueNative(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "native_rescue_failed");
    }

    function _refundToken(address token, bytes32 guid, string memory reason, address refundBsc, uint256 amount) internal {
        if (refundBsc == address(0)) revert InvalidRefundAddress();

        bool ok = true;
        if (amount > 0 && token != address(0)) {
            ok = _tryTransfer(token, refundBsc, amount);
        }
        if (!ok) emit RefundFailed(guid, token, refundBsc, amount);

        emit RouteFailed(guid, reason, refundBsc, amount);
        _refundNative(refundBsc);
    }

    function _refundNative(address to) internal {
        if (to == address(0)) return;
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = to.call{value: bal}("");
        ok;
    }

    function _fail(bytes32 guid, string memory reason, address refundBsc, uint256 amountLD) internal {
        emit RouteFailed(guid, reason, refundBsc, amountLD);
        if (refundBsc != address(0)) _refundNative(refundBsc);
    }

    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!success) return false;
        if (data.length == 0) return true;
        return abi.decode(data, (bool));
    }

    receive() external payable {}
}
