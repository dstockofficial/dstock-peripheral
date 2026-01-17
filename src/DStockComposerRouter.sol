// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {WrappedNativePayoutHelper} from "./WrappedNativePayoutHelper.sol";

/// @dev Minimal LayerZero OFT compose message decoder used by `lzCompose`.
///
/// LayerZero compose payload format (EVM OFT):
/// `nonce(8) | srcEid(4) | amountLD(32) | composeFrom(32) | composeMsg(bytes)`
///
/// Notes:
/// - `amountLD` is the amount *credited* to this contract on the token/OFT side before `lzCompose` is executed.
/// - `composeMsg` is arbitrary bytes provided by the sender; in this router it is expected to be `abi.encode(RouteMsg)`
///   for forward or `abi.encode(ReverseRouteMsg)` for reverse.
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

/// @dev Minimal interface for an EVM OFT token / adapter.
/// In this repo we use the same interface for:
/// - `shareAdapter` (bridging wrapper shares to destination)
/// - `underlying` (reverse hop: bridging underlying token to destination)
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

/// @dev Minimal wrapper interface used by this router.
/// - `wrap(token, amount, to)`: consumes `token` and mints wrapper shares (18 decimals)
/// - `unwrap(token, amount18, to)`: burns shares and returns `token` to `to`
interface IDStockWrapperLike {
    function wrap(address token, uint256 amount, address to) external returns (uint256 net18, uint256 mintedShares);
    function unwrap(address token, uint256 amount, address to) external;
}

/// @dev Optional wrapper view interface used for quoting user wraps.
/// If a wrapper does not implement this, `quoteWrapAndBridge` will revert.
interface IDStockWrapperPreview {
    function previewWrap(address token, uint256 amount) external view returns (uint256 net18, uint256 fee);
}

/// @dev Minimal WETH9/WBNB interface for wrapping native gas token into ERC20.
interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/// @dev LayerZero v2 compose interface (EndpointV2 calls this on the compose target).
interface IOAppComposer {
    function lzCompose(
        address _oApp,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

/// @title DStockComposerRouter
/// @notice Unified router for the DStock ecosystem (UUPS upgradeable).
///
/// This contract combines:
/// - **User entry (BSC)**: `wrapAndBridge` / `quoteWrapAndBridge`
/// - **LayerZero compose callback**: `lzCompose` (forward + reverse)
///
/// ### High-level flows
/// - **Forward (compose)**: an `underlying` token is credited to this router -> wrap into `wrapper` shares -> bridge shares via `shareAdapter`.
/// - **Reverse (compose)**: `wrapper` shares are credited to this router via `shareAdapter` -> unwrap into `underlying` -> either:
///   - deliver locally if `finalDstEid == chainEid`, or
///   - bridge underlying via the `underlying` OFT token.
///
/// ### Registries (owner configured)
/// - `underlyingToWrapper[underlying] = wrapper`
/// - `underlyingToShareAdapter[underlying] = shareAdapter`
/// - `shareAdapterToWrapper[shareAdapter] = wrapper` (used to identify reverse compose)
///
/// ### Safety / behavior notes
/// - **Idempotency**: `processedGuids[guid]` ensures a compose GUID is processed at most once.
/// - **Compose failure handling**: most compose-path failures do **not** revert; the router emits `RouteFailed` and
///   attempts to refund tokens / native fee to `refundBsc` (best effort).
/// - **Hard reverts**: `lzCompose` still reverts for `NotEndpoint` and for unknown `_oApp` (`InvalidOApp`).
contract DStockComposerRouter is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IOAppComposer
{
    using OFTComposeMsgCodecLite for bytes;
    using SafeERC20 for IERC20;

    /// @notice LayerZero EndpointV2 address on this chain.
    address public endpoint;

    /// @notice The LayerZero EID of the chain this router is deployed on.
    /// Used only for reverse-route local delivery checks.
    uint32 public chainEid;

    /// @notice Underlying token (either OFT or local ERC20) -> wrapper (shares token + wrap/unwrap interface).
    mapping(address => address) public underlyingToWrapper;

    /// @notice Underlying token (either OFT or local ERC20) -> shareAdapter (OFT adapter for shares to destination).
    mapping(address => address) public underlyingToShareAdapter;

    /// @notice shareAdapter -> wrapper (reverse-route identification and unwrap routing).
    mapping(address => address) public shareAdapterToWrapper;

    /// @notice Compose GUIDs already processed (idempotency).
    mapping(bytes32 => bool) public processedGuids;

    /// @notice Wrapped native token (e.g., WBNB/WETH) used by `wrapAndBridgeNative`.
    /// @dev Owner must configure this and register a route via `setRouteConfig(wrappedNative, wrapper, shareAdapter)`.
    address public wrappedNative;
    /// @notice Helper used to unwrap wrappedNative and pay native to receiver on reverse local delivery.
    /// @dev Deployed separately; set via `setWrappedNativePayoutHelper`.
    address public wrappedNativePayoutHelper;

    uint256[43] private __gap;

    /// @notice Emitted when an underlying forward route is configured.
    event UnderlyingConfigSet(address indexed underlying, address indexed wrapper, address indexed shareAdapter);
    /// @notice Emitted when a shareAdapter reverse route is configured.
    event ShareAdapterWrapperSet(address indexed shareAdapter, address indexed wrapper);

    /// @notice Forward compose success: underlying was wrapped and shares were bridged to `finalDstEid/finalTo`.
    event WrappedAndForwarded(bytes32 indexed guid, uint32 finalDstEid, bytes32 finalTo, uint256 underlyingIn, uint256 sharesOut);
    /// @notice Reverse compose success: shares were unwrapped and underlying was delivered/bridged to `finalDstEid/finalTo`.
    event UnwrappedAndForwarded(bytes32 indexed guid, uint32 finalDstEid, bytes32 finalTo, uint256 sharesIn, uint256 underlyingOut);
    /// @notice Any route failure (compose paths). `amountLD` is the token amount attempted/refunded (best effort).
    event RouteFailed(bytes32 indexed guid, string reason, address refundBsc, uint256 amountLD);
    /// @notice Token refund failed (token might require a different transfer method); owner can rescue later.
    event RefundFailed(bytes32 indexed guid, address indexed token, address indexed refundBsc, uint256 amount);

    error ZeroAddress();
    error NotEndpoint();
    error InvalidOApp();
    error InvalidRefundAddress();
    error AmountZero();
    error InvalidRecipient();
    error InsufficientFee(uint256 provided, uint256 required);
    error RefundFailedNative();
    error WrappedNativeNotSet();

    /// @notice Forward-route payload encoded inside LayerZero `composeMsg` (`abi.encode(RouteMsg)`).
    struct RouteMsg {
        /// @notice Final destination EID for shares (second hop).
        uint32 finalDstEid;
        /// @notice Final recipient on destination chain (bytes32-encoded).
        bytes32 finalTo;
        /// @notice EVM address on this chain used for refunding tokens/native fees if something fails.
        address refundBsc;
        /// @notice Minimum shares for the second hop (0 = accept quoted amount).
        uint256 minAmountLD2;
    }

    /// @notice Reverse-route payload encoded inside LayerZero `composeMsg` (`abi.encode(ReverseRouteMsg)`).
    struct ReverseRouteMsg {
        /// @notice Underlying token address (OFT token/adapter on EVM side) to receive after unwrapping.
        address underlying;
        /// @notice Final destination EID for underlying (second hop). If equals `chainEid`, deliver locally on this chain.
        uint32 finalDstEid;
        /// @notice Final recipient (bytes32-encoded). If delivering locally, this must encode an EVM address.
        bytes32 finalTo;
        /// @notice EVM address on this chain used for refunding tokens/native fees if something fails.
        address refundBsc;
        /// @notice Portion of shares to unwrap, in basis points (1..10000).
        uint16 unwrapBps;
        /// @notice Minimum underlying for the second hop (0 = accept unwrapped amount).
        uint256 minAmountLD2;
        /// @notice LayerZero options for the second hop (underlying.send).
        bytes extraOptions2;
        /// @notice Optional compose payload for the second hop (underlying.send).
        bytes composeMsg2;
    }

    /// @notice UUPS initializer (called once via proxy).
    /// @param _endpoint LayerZero EndpointV2 address on this chain
    /// @param _chainEid LayerZero EID for this chain
    /// @param _owner Owner/admin that can configure routes and upgrade
    function initialize(address _endpoint, uint32 _chainEid, address _owner) external initializer {
        if (_endpoint == address(0) || _owner == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        endpoint = _endpoint;
        chainEid = _chainEid;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}


    /// @notice Configure routing for one wrapper/shareAdapter pair (and optionally one underlying).
    /// @dev Always registers the reverse mapping `shareAdapter -> wrapper` (needed for reverse compose).
    /// If `underlying != address(0)`, also registers forward mappings `underlying -> (wrapper, shareAdapter)`.
    ///
    /// This function can be called multiple times to register multiple underlyings that share the same wrapper/shareAdapter.
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

    /// @notice Configure wrapped native token (e.g., WBNB/WETH) for `wrapAndBridgeNative`.
    function setWrappedNative(address wrappedNative_) external onlyOwner {
        if (wrappedNative_ == address(0)) revert ZeroAddress();
        wrappedNative = wrappedNative_;
    }

    /// @notice Configure the helper used for reverse local native delivery (WBNB/WETH -> native payout).
    /// @dev This helper must be deployed as a standalone contract (see `src/WrappedNativePayoutHelper.sol`).
    function setWrappedNativePayoutHelper(address helper) external onlyOwner {
        if (helper == address(0)) revert ZeroAddress();
        wrappedNativePayoutHelper = helper;
    }

    /// @notice User entry: wrap an underlying token into wrapper shares, then bridge shares via `shareAdapter`.
    /// @param underlying Underlying token on this chain (local ERC20 or OFT token)
    /// @param amount Amount of underlying in its own decimals
    /// @param dstEid Destination EID for shares
    /// @param to Recipient on destination chain (bytes32-encoded)
    /// @param extraOptions LayerZero options for `shareAdapter.send`
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

    /// @notice User entry: wrap native gas token (BNB/ETH) into `wrappedNative` (WBNB/WETH), then wrap into shares and bridge.
    /// @dev `msg.value` must cover `amountNative` + LayerZero native fee. Any leftover fee is refunded to `msg.sender`.
    function wrapAndBridgeNative(
        uint256 amountNative,
        uint32 dstEid,
        bytes32 to,
        bytes calldata extraOptions
    ) external payable nonReentrant returns (uint256 amountSentLD) {
        if (amountNative == 0) revert AmountZero();
        if (to == bytes32(0)) revert InvalidRecipient();

        address w = wrappedNative;
        if (w == address(0)) revert WrappedNativeNotSet();
        if (msg.value < amountNative) revert InsufficientFee(msg.value, amountNative);

        // 1) Wrap native into ERC20 on this router.
        IWrappedNative(w).deposit{value: amountNative}();

        // 2) Reuse the same wrap + bridge pipeline, using `w` as the underlying token.
        address wrapper = underlyingToWrapper[w];
        address shareAdapter = underlyingToShareAdapter[w];
        if (wrapper == address(0) || shareAdapter == address(0)) revert InvalidOApp();

        IERC20(w).forceApprove(wrapper, amountNative);
        (uint256 net18, ) = IDStockWrapperLike(wrapper).wrap(w, amountNative, address(this));
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
        uint256 availableFee = msg.value - amountNative;
        if (availableFee < fee.nativeFee) revert InsufficientFee(availableFee, fee.nativeFee);

        IOFTLike(shareAdapter).send{value: fee.nativeFee}(sp, fee, msg.sender);

        uint256 refund = availableFee - fee.nativeFee;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailedNative();
        }
    }

    /// @notice Quote the LayerZero fee (native) for user wrap + bridge.
    /// @dev Requires wrapper to implement `previewWrap`.
    /// @return nativeFee The required native fee for `shareAdapter.send` (wrap cost excluded)
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

    /// @notice LayerZero compose callback entrypoint.
    ///
    /// Important parameters (LayerZero terminology):
    /// - `_oApp`: the OApp address associated with the compose call.
    ///   - Forward: `_oApp == underlying oft` (the token credited to this router)
    ///   - Reverse: `_oApp == shareAdapter` (shares adapter credited shares to this router)
    /// - `_guid`: globally unique message id used for idempotency (`processedGuids`)
    /// - `_message`: OFT compose payload, decoded via `OFTComposeMsgCodecLite` to extract `amountLD` and `composeMsg`.
    function lzCompose(
        address _oApp,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable nonReentrant {
        if (msg.sender != endpoint) revert NotEndpoint();

        // Idempotency: LayerZero may retry compose; we must not double-process the same GUID.
        if (processedGuids[_guid]) return;
        processedGuids[_guid] = true;

        // Decode the OFT compose container:
        // - `amountLD`: amount credited to this router before compose executes
        // - `inner`: our router payload (abi-encoded RouteMsg/ReverseRouteMsg)
        bytes memory inner = _message.composeMsg();
        uint256 amountLD = _message.amountLD();

        // Reverse: _oApp is a supported shareAdapter
        address wrapper = shareAdapterToWrapper[_oApp];
        if (wrapper != address(0)) {
            // Reverse path consumes shares (`amountLD`) and produces underlying.
            _lzComposeReverse(wrapper, _guid, amountLD, inner);
            return;
        }

        // Forward: _oApp is the underlying token (OFT token) that was credited to this router
        address shareAdapter = underlyingToShareAdapter[_oApp];
        wrapper = underlyingToWrapper[_oApp];
        if (wrapper == address(0) || shareAdapter == address(0)) revert InvalidOApp();

        // Forward path consumes underlying (`amountLD`) and produces shares bridged via `shareAdapter`.
        _lzComposeForward(_oApp, wrapper, shareAdapter, _guid, amountLD, inner);
    }

    /// @dev Forward compose path: decode `RouteMsg`, wrap underlying into shares, then send shares.
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
            // Bad payload: nothing to do; emit a failure and stop.
            _fail(guid, "decode_route_failed", address(0), underlyingAmount);
            return;
        }
        if (r.refundBsc == address(0)) {
            // Refund address is mandatory because we avoid reverting compose on failures.
            _fail(guid, "refund_zero", address(0), underlyingAmount);
            return;
        }

        // 1) Wrap underlying into 18-decimal shares (kept on this router initially).
        uint256 sharesOut = _wrapUnderlying(wrapper, underlying, guid, underlyingAmount, r.refundBsc);
        if (sharesOut == 0) return;

        // 2) Bridge shares via shareAdapter (second hop).
        bool ok = _sendShares(wrapper, shareAdapter, guid, underlyingAmount, sharesOut, r.finalDstEid, r.finalTo, r.refundBsc, r.minAmountLD2);
        if (!ok) return;

        // 3) Any leftover native (from msg.value forwarded by endpoint) is best-effort refunded.
        _refundNative(r.refundBsc);
    }

    /// @dev Reverse compose path: decode `ReverseRouteMsg`, unwrap shares into underlying, then deliver locally or send underlying.
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
            // We can't unwrap into a zero address token; refund shares.
            _refundToken(wrapper, guid, "underlying_zero", r.refundBsc, sharesIn);
            return;
        }
        if (r.unwrapBps == 0 || r.unwrapBps > 10_000) {
            // Unwrap fraction is expressed in bps (1..10000).
            _refundToken(wrapper, guid, "bad_unwrap_bps", r.refundBsc, sharesIn);
            return;
        }

        // 1) Unwrap shares into underlying.
        uint256 underlyingOut = _unwrapShares(wrapper, r.underlying, guid, sharesIn, r.refundBsc, r.unwrapBps);
        if (underlyingOut == 0) return;

        if (r.finalDstEid == chainEid) {
            // Local delivery (reverse only): finalTo must encode an EVM address on this chain.
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

            // Special case: deliver native gas token when underlying is `wrappedNative` (e.g., WBNB/WETH).
            // Rule: `underlying == wrappedNative && finalDstEid == chainEid` => unwrap via helper + native transfer.
            if (r.underlying == wrappedNative) {
                address helper = wrappedNativePayoutHelper;
                if (helper == address(0)) {
                    _refundToken(r.underlying, guid, "native_helper_not_set", r.refundBsc, underlyingOut);
                    return;
                }

                // Move wrapped tokens to helper, then helper unwraps and delivers native.
                IERC20(r.underlying).safeTransfer(helper, underlyingOut);
                bool okNative = WrappedNativePayoutHelper(payable(helper)).unwrapAndPayout(wrappedNative, receiver, r.refundBsc, underlyingOut);
                if (!okNative) {
                    // helper already refunded wrapped/native best-effort to refundBsc
                    emit RouteFailed(guid, "deliver_native_failed", r.refundBsc, underlyingOut);
                    _refundNative(r.refundBsc);
                    return;
                }

                emit UnwrappedAndForwarded(guid, r.finalDstEid, r.finalTo, sharesIn, underlyingOut);
            } else {
                // Best-effort token transfer; if it fails, refund to refundBsc.
                bool okDeliver = _tryTransfer(r.underlying, receiver, underlyingOut);
                if (!okDeliver) {
                    _refundToken(r.underlying, guid, "deliver_failed", r.refundBsc, underlyingOut);
                    return;
                }
                emit UnwrappedAndForwarded(guid, r.finalDstEid, r.finalTo, sharesIn, underlyingOut);
            }
        } else {
            // Cross-chain delivery: send underlying via its OFT interface (second hop).
            bool ok2 = _sendUnderlyingToFinal(r.underlying, guid, sharesIn, underlyingOut, r);
            if (!ok2) return;
        }

        _refundNative(r.refundBsc);
    }

    /// @dev Wrap underlying into wrapper shares. On failure, attempts to refund `underlyingAmount` to `refundBsc`.
    function _wrapUnderlying(address wrapper, address underlying, bytes32 guid, uint256 underlyingAmount, address refundBsc)
        internal
        returns (uint256)
    {
        // Compose assumption: `underlyingAmount` tokens should already be on this router.
        uint256 balUnderlying = IERC20(underlying).balanceOf(address(this));
        if (balUnderlying < underlyingAmount) {
            _refundToken(underlying, guid, "insufficient_underlying", refundBsc, underlyingAmount);
            return 0;
        }

        // Approve wrapper to pull the underlying for wrapping.
        IERC20(underlying).forceApprove(wrapper, underlyingAmount);

        // Measure shares minted to this router (supports wrappers that don't return exact values).
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

    /// @dev Second hop for forward path: send wrapper shares via `shareAdapter`.
    /// Uses `refundBsc` as the refund address for LayerZero native fee.
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

        // Second hop: bridge wrapper shares via shareAdapter (OFT adapter).
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

    /// @dev Externalized decode to allow try/catch around abi.decode.
    function _decodeRouteMsg(bytes memory inner) external pure returns (RouteMsg memory) {
        return abi.decode(inner, (RouteMsg));
    }

    /// @dev Externalized decode to allow try/catch around abi.decode.
    function _decodeReverseRouteMsg(bytes memory inner) external pure returns (ReverseRouteMsg memory) {
        return abi.decode(inner, (ReverseRouteMsg));
    }

    /// @dev Unwrap `sharesIn * unwrapBps/10000` shares into underlying.
    /// On unwrap failure, refunds the full `sharesIn` (shares token) to `refundBsc`.
    function _unwrapShares(address wrapper, address underlying, bytes32 guid, uint256 sharesIn, address refundBsc, uint16 unwrapBps)
        internal
        returns (uint256)
    {
        // Compose assumption: `sharesIn` shares should already be on this router.
        uint256 balShares = IERC20(wrapper).balanceOf(address(this));
        if (balShares < sharesIn) {
            _refundToken(wrapper, guid, "insufficient_shares", refundBsc, sharesIn);
            return 0;
        }

        // We may choose to unwrap only a fraction of shares (basis points).
        uint256 attemptUnderlying = (sharesIn * uint256(unwrapBps)) / 10_000;
        if (attemptUnderlying == 0) {
            _refundToken(wrapper, guid, "unwrap_zero_amount", refundBsc, sharesIn);
            return 0;
        }

        // Track underlying delta to compute actual output.
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

    /// @dev Second hop for reverse path: send `underlyingOut` via the `underlying` OFT token.
    /// Uses `r.refundBsc` as the refund address for LayerZero native fee.
    function _sendUnderlyingToFinal(address underlying, bytes32 guid, uint256 sharesIn, uint256 underlyingOut, ReverseRouteMsg memory r)
        internal
        returns (bool)
    {
        // Second hop: bridge underlying via its OFT interface.
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
    /// @notice Rescue ERC20 tokens from this contract (admin only).
    /// @dev Intended for edge cases where a refund failed and funds are stuck.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Rescue native gas token from this contract (admin only).
    function rescueNative(address to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "native_rescue_failed");
    }

    /// @dev Best-effort refund path for compose failures:
    /// - try refunding `amount` of `token` to `refundBsc`
    /// - emit `RefundFailed` if token transfer fails
    /// - emit `RouteFailed` always
    /// - attempt refunding any native balance to `refundBsc`
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

    /// @dev Best-effort native refund: sends the contract's entire native balance to `to`.
    /// This is intentionally non-reverting (failure is ignored).
    function _refundNative(address to) internal {
        if (to == address(0)) return;
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = to.call{value: bal}("");
        ok;
    }

    /// @dev Emit failure and optionally refund native balance (no token refunds).
    function _fail(bytes32 guid, string memory reason, address refundBsc, uint256 amountLD) internal {
        emit RouteFailed(guid, reason, refundBsc, amountLD);
        if (refundBsc != address(0)) _refundNative(refundBsc);
    }

    /// @dev Low-level ERC20 transfer attempt that supports non-standard ERC20s.
    /// Returns `false` if the call reverts or returns `false`.
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool) {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!success) return false;
        if (data.length == 0) return true;
        return abi.decode(data, (bool));
    }

    receive() external payable {}
}
