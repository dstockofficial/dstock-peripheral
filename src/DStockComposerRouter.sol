// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
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
 * - Forward: receives `underlyingOft` (credited on lzReceive) -> wraps into `wrapper` shares -> sends shares via `shareAdapter`.
 * - Reverse: receives wrapper shares via `shareAdapter` -> unwraps into `underlyingOft` -> sends underlying to the final chain.
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
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IOAppComposer
{
    using OFTComposeMsgCodecLite for bytes;
    using SafeERC20 for IERC20;

    /// @notice BSC EndpointV2 address
    address public endpoint;

    /// @notice OApp/Adapter address -> asset config ID
    mapping(address => bytes32) public oAppToConfigId;

    struct AssetConfig {
        bool isSet;
        bool deprecated;
        address underlyingOft; // token OFT on BSC
        address wrapper; // share ERC20 + wrap/unwrap
        address shareAdapter; // OFT adapter for shares
        bool forwardPaused;
        bool reversePaused;
        uint8 sharedDecimals; // optional (dust handling / normalization)
    }

    mapping(bytes32 => AssetConfig) public assetConfigs;
    mapping(bytes32 => bool) public processedGuids;

    uint256[50] private __gap;

    event AssetAdded(bytes32 indexed configId, address indexed underlyingOft, address indexed wrapper, address shareAdapter, uint8 sharedDecimals);
    event AssetDeprecated(bytes32 indexed configId);
    event AssetPauseSet(bytes32 indexed configId, bool forwardPaused, bool reversePaused);

    event WrappedAndForwarded(bytes32 indexed guid, uint32 finalDstEid, bytes32 finalTo, uint256 underlyingIn, uint256 sharesOut);
    event UnwrappedAndForwarded(bytes32 indexed guid, uint32 finalDstEid, bytes32 finalTo, uint256 sharesIn, uint256 underlyingOut);
    event RouteFailed(bytes32 indexed guid, string reason, address refundBsc, uint256 amountLD);
    event RefundFailed(bytes32 indexed guid, address indexed token, address indexed refundBsc, uint256 amount);

    error ZeroAddress();
    error NotEndpoint();
    error InvalidOApp();
    error AlreadyRegistered(address oApp);
    error UnknownConfig(bytes32 configId);
    error InvalidRefundAddress();

    struct RouteMsg {
        uint32 finalDstEid;
        bytes32 finalTo;
        address refundBsc;
        uint256 minAmountLD2;
    }

    struct ReverseRouteMsg {
        uint32 finalDstEid;
        bytes32 finalTo;
        address refundBsc;
        uint16 unwrapBps;
        uint256 minAmountLD2;
        bytes extraOptions2;
        bytes composeMsg2;
    }

    function initialize(address _endpoint, address _owner) external initializer {
        if (_endpoint == address(0) || _owner == address(0)) revert ZeroAddress();
        __Ownable_init(_owner);
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        endpoint = _endpoint;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function addAsset(address _underlyingOft, address _wrapper, address _shareAdapter, uint8 _sharedDecimals)
        external
        onlyOwner
        returns (bytes32 configId)
    {
        if (_underlyingOft == address(0) || _wrapper == address(0) || _shareAdapter == address(0)) revert ZeroAddress();
        if (oAppToConfigId[_underlyingOft] != bytes32(0)) revert AlreadyRegistered(_underlyingOft);
        if (oAppToConfigId[_shareAdapter] != bytes32(0)) revert AlreadyRegistered(_shareAdapter);

        configId = keccak256(abi.encodePacked(_underlyingOft, _wrapper, _shareAdapter));

        AssetConfig storage cfg = assetConfigs[configId];
        cfg.isSet = true;
        cfg.deprecated = false;
        cfg.underlyingOft = _underlyingOft;
        cfg.wrapper = _wrapper;
        cfg.shareAdapter = _shareAdapter;
        cfg.forwardPaused = false;
        cfg.reversePaused = false;
        cfg.sharedDecimals = _sharedDecimals;

        oAppToConfigId[_underlyingOft] = configId;
        oAppToConfigId[_shareAdapter] = configId;

        emit AssetAdded(configId, _underlyingOft, _wrapper, _shareAdapter, _sharedDecimals);
    }

    function deprecateAsset(bytes32 configId) external onlyOwner {
        AssetConfig storage cfg = assetConfigs[configId];
        if (!cfg.isSet) revert UnknownConfig(configId);
        cfg.deprecated = true;
        cfg.forwardPaused = true;
        cfg.reversePaused = true;

        if (oAppToConfigId[cfg.underlyingOft] == configId) oAppToConfigId[cfg.underlyingOft] = bytes32(0);
        if (oAppToConfigId[cfg.shareAdapter] == configId) oAppToConfigId[cfg.shareAdapter] = bytes32(0);

        emit AssetDeprecated(configId);
    }

    function setAssetPause(bytes32 configId, bool forwardPaused_, bool reversePaused_) external onlyOwner {
        AssetConfig storage cfg = assetConfigs[configId];
        if (!cfg.isSet) revert UnknownConfig(configId);
        cfg.forwardPaused = forwardPaused_;
        cfg.reversePaused = reversePaused_;
        emit AssetPauseSet(configId, forwardPaused_, reversePaused_);
    }

    function lzCompose(
        address _oApp,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable nonReentrant {
        if (msg.sender != endpoint) revert NotEndpoint();
        if (processedGuids[_guid]) return; // do not revert (avoid blocking)
        processedGuids[_guid] = true;

        bytes32 configId = oAppToConfigId[_oApp];
        if (configId == bytes32(0)) revert InvalidOApp();

        AssetConfig storage cfg = assetConfigs[configId];
        if (!cfg.isSet || cfg.deprecated) revert InvalidOApp();

        bytes memory inner = _message.composeMsg();

        if (_oApp == cfg.underlyingOft) {
            uint256 underlyingAmount = _message.amountLD();

            RouteMsg memory r;
            try this._decodeRouteMsg(inner) returns (RouteMsg memory rr) {
                r = rr;
            } catch {
                _fail(_guid, "decode_route_failed", address(0), underlyingAmount);
                return;
            }
            if (r.refundBsc == address(0)) {
                _fail(_guid, "refund_zero", address(0), underlyingAmount);
                return;
            }

            if (paused() || cfg.forwardPaused) {
                _refundToken(cfg.underlyingOft, _guid, "paused", r.refundBsc, underlyingAmount);
                return;
            }

            uint256 sharesOut = _wrapUnderlying(cfg, _guid, underlyingAmount, r.refundBsc);
            if (sharesOut == 0) return;

            bool ok = _sendShares(cfg, _guid, underlyingAmount, sharesOut, r);
            if (!ok) return;

            _refundNative(r.refundBsc);
            return;
        }

        if (_oApp == cfg.shareAdapter) {
            uint256 sharesIn = _message.amountLD();

            ReverseRouteMsg memory r;
            try this._decodeReverseRouteMsg(inner) returns (ReverseRouteMsg memory rr) {
                r = rr;
            } catch {
                _fail(_guid, "decode_reverse_route_failed", address(0), sharesIn);
                return;
            }
            if (r.refundBsc == address(0)) {
                _fail(_guid, "refund_zero", address(0), sharesIn);
                return;
            }
            if (r.unwrapBps == 0 || r.unwrapBps > 10_000) {
                _refundToken(cfg.wrapper, _guid, "bad_unwrap_bps", r.refundBsc, sharesIn);
                return;
            }

            if (paused() || cfg.reversePaused) {
                _refundToken(cfg.wrapper, _guid, "paused", r.refundBsc, sharesIn);
                return;
            }

            uint256 underlyingOut = _unwrapShares(cfg, _guid, sharesIn, r);
            if (underlyingOut == 0) return;

            bool ok2 = _sendUnderlyingToFinal(cfg, _guid, sharesIn, underlyingOut, r);
            if (!ok2) return;

            _refundNative(r.refundBsc);
            return;
        }

        revert InvalidOApp();
    }

    function _wrapUnderlying(AssetConfig storage cfg, bytes32 guid, uint256 underlyingAmount, address refundBsc)
        internal
        returns (uint256)
    {
        uint256 balUnderlying = IERC20(cfg.underlyingOft).balanceOf(address(this));
        if (balUnderlying < underlyingAmount) {
            _refundToken(cfg.underlyingOft, guid, "insufficient_underlying", refundBsc, underlyingAmount);
            return 0;
        }

        IERC20(cfg.underlyingOft).forceApprove(cfg.wrapper, underlyingAmount);

        uint256 shareBalBefore = IERC20(cfg.wrapper).balanceOf(address(this));
        IDStockWrapperLike(cfg.wrapper).wrap(cfg.underlyingOft, underlyingAmount, address(this));
        uint256 shareBalAfter = IERC20(cfg.wrapper).balanceOf(address(this));
        uint256 sharesOut = shareBalAfter - shareBalBefore;

        if (sharesOut == 0) {
            _refundToken(cfg.underlyingOft, guid, "wrap_zero_shares", refundBsc, underlyingAmount);
            return 0;
        }
        return sharesOut;
    }

    function _sendShares(AssetConfig storage cfg, bytes32 guid, uint256 underlyingIn, uint256 sharesOut, RouteMsg memory r)
        internal
        returns (bool)
    {
        uint256 minShares = r.minAmountLD2 == 0 ? sharesOut : r.minAmountLD2;

        IOFTLike.SendParam memory sp = IOFTLike.SendParam({
            dstEid: r.finalDstEid,
            to: r.finalTo,
            amountLD: sharesOut,
            minAmountLD: minShares,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        IOFTLike.MessagingFee memory fee2 = IOFTLike(cfg.shareAdapter).quoteSend(sp, false);
        if (address(this).balance < fee2.nativeFee) {
            _refundToken(cfg.wrapper, guid, "fee_insufficient", r.refundBsc, sharesOut);
            return false;
        }

        IERC20(cfg.wrapper).forceApprove(cfg.shareAdapter, sharesOut);

        try IOFTLike(cfg.shareAdapter).send{value: fee2.nativeFee}(sp, fee2, r.refundBsc) {
            emit WrappedAndForwarded(guid, r.finalDstEid, r.finalTo, underlyingIn, sharesOut);
            return true;
        } catch {
            _refundToken(cfg.wrapper, guid, "send2_failed", r.refundBsc, sharesOut);
            return false;
        }
    }

    function _decodeRouteMsg(bytes memory inner) external pure returns (RouteMsg memory) {
        return abi.decode(inner, (RouteMsg));
    }

    function _decodeReverseRouteMsg(bytes memory inner) external pure returns (ReverseRouteMsg memory) {
        return abi.decode(inner, (ReverseRouteMsg));
    }

    function _unwrapShares(AssetConfig storage cfg, bytes32 guid, uint256 sharesIn, ReverseRouteMsg memory r)
        internal
        returns (uint256)
    {
        uint256 balShares = IERC20(cfg.wrapper).balanceOf(address(this));
        if (balShares < sharesIn) {
            _refundToken(cfg.wrapper, guid, "insufficient_shares", r.refundBsc, sharesIn);
            return 0;
        }

        uint256 attemptUnderlying = (sharesIn * uint256(r.unwrapBps)) / 10_000;
        if (attemptUnderlying == 0) {
            _refundToken(cfg.wrapper, guid, "unwrap_zero_amount", r.refundBsc, sharesIn);
            return 0;
        }

        uint256 underlyingBalBefore = IERC20(cfg.underlyingOft).balanceOf(address(this));

        try IDStockWrapperLike(cfg.wrapper).unwrap(cfg.underlyingOft, attemptUnderlying, address(this)) {} catch {
            _refundToken(cfg.wrapper, guid, "unwrap_failed", r.refundBsc, sharesIn);
            return 0;
        }

        uint256 underlyingBalAfter = IERC20(cfg.underlyingOft).balanceOf(address(this));
        uint256 underlyingOut = underlyingBalAfter - underlyingBalBefore;
        if (underlyingOut == 0) {
            _refundToken(cfg.wrapper, guid, "unwrap_zero_out", r.refundBsc, sharesIn);
            return 0;
        }
        return underlyingOut;
    }

    function _sendUnderlyingToFinal(AssetConfig storage cfg, bytes32 guid, uint256 sharesIn, uint256 underlyingOut, ReverseRouteMsg memory r)
        internal
        returns (bool)
    {
        uint256 minUnderlying = r.minAmountLD2 == 0 ? underlyingOut : r.minAmountLD2;
        if (underlyingOut < minUnderlying) {
            _refundToken(cfg.underlyingOft, guid, "underlying_below_min", r.refundBsc, underlyingOut);
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

        IOFTLike.MessagingFee memory fee2 = IOFTLike(cfg.underlyingOft).quoteSend(sp, false);
        if (address(this).balance < fee2.nativeFee) {
            _refundToken(cfg.underlyingOft, guid, "fee_insufficient", r.refundBsc, underlyingOut);
            return false;
        }

        try IOFTLike(cfg.underlyingOft).send{value: fee2.nativeFee}(sp, fee2, r.refundBsc) {
            emit UnwrappedAndForwarded(guid, r.finalDstEid, r.finalTo, sharesIn, underlyingOut);
            return true;
        } catch {
            _refundToken(cfg.underlyingOft, guid, "send2_failed", r.refundBsc, underlyingOut);
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
