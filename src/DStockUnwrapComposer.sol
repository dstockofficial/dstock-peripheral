// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDStockWrapper} from "./interfaces/IDStockWrapper.sol";

interface IOAppCore {
    function endpoint() external view returns (address);
}

interface IOAppComposer {
    function lzCompose(
        address _oft,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

library OFTComposeMsgCodecLite {
    uint8 private constant NONCE_OFFSET = 8;
    uint8 private constant SRC_EID_OFFSET = 12;
    uint8 private constant AMOUNT_LD_OFFSET = 44;

    function amountLD(bytes calldata _msg) internal pure returns (uint256) {
        return uint256(bytes32(_msg[SRC_EID_OFFSET:AMOUNT_LD_OFFSET]));
    }
}

/// @title DStockUnwrapComposer
/// @notice Handles HyperEVM -> BSC compose to unwrap into fixed underlying.
contract DStockUnwrapComposer is IOAppComposer, ReentrancyGuard {
    uint8 private constant COMPOSE_FROM_OFFSET = 76;

    address public immutable ENDPOINT;
    address public immutable OFT_ADAPTER;
    IDStockWrapper public immutable WRAPPER;
    address public immutable UNDERLYING;

    event ComposedUnwrap(
        bytes32 indexed guid,
        address indexed oft,
        address indexed receiver,
        uint256 amountLD,
        uint256 amountToken
    );

    event ComposeFailed(bytes32 indexed guid, bytes reason);

    error OnlyEndpoint();
    error OnlySelf();
    error ZeroAddress();
    error InvalidComposeCaller(address expected, address actual);
    error InvalidRecipient();
    error UnderlyingDisabled();
    error TooSmall();

    constructor(address _wrapper, address _underlying, address _oftAdapter) {
        if (
            _wrapper == address(0) ||
            _underlying == address(0) ||
            _oftAdapter == address(0)
        ) revert ZeroAddress();

        WRAPPER = IDStockWrapper(_wrapper);
        UNDERLYING = _underlying;
        OFT_ADAPTER = _oftAdapter;
        ENDPOINT = IOAppCore(_oftAdapter).endpoint();
    }

    function lzCompose(
        address _oft,
        bytes32 _guid,
        bytes calldata _message,
        address /*_executor*/,
        bytes calldata /*_extraData*/
    ) external payable override nonReentrant {
        if (msg.sender != ENDPOINT) revert OnlyEndpoint();
        if (_oft != OFT_ADAPTER) revert InvalidComposeCaller(OFT_ADAPTER, _oft);

        uint256 amountLD = OFTComposeMsgCodecLite.amountLD(_message);
        address receiver = _decodeReceiver(_message);

        (bool enabled, uint8 decimals, ) = WRAPPER.underlyingInfo(UNDERLYING);
        if (!enabled || decimals == 0) revert UnderlyingDisabled();

        uint256 amountToken = _rescale(amountLD, 18, decimals);
        if (amountToken == 0) revert TooSmall();

        try this._executeUnwrap(amountLD, amountToken, receiver) {
            emit ComposedUnwrap(_guid, _oft, receiver, amountLD, amountToken);
        } catch (bytes memory reason) {
            emit ComposeFailed(_guid, reason);
        }
    }

    function _executeUnwrap(
        uint256 amountLD,
        uint256 amountToken,
        address receiver
    ) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (receiver == address(0)) revert InvalidRecipient();
        if (amountLD == 0) revert TooSmall();

        WRAPPER.unwrap(UNDERLYING, amountToken, receiver);
    }

    function _decodeReceiver(
        bytes calldata message
    ) internal pure returns (address) {
        if (message.length < COMPOSE_FROM_OFFSET + 32)
            revert InvalidRecipient();

        bytes32 receiverBytes = bytes32(
            message[COMPOSE_FROM_OFFSET:COMPOSE_FROM_OFFSET + 32]
        );
        address receiver = address(uint160(uint256(receiverBytes)));
        if (receiver == address(0)) revert InvalidRecipient();
        return receiver;
    }

    function _rescale(
        uint256 amount,
        uint8 fromDec,
        uint8 toDec
    ) internal pure returns (uint256) {
        if (amount == 0 || fromDec == toDec) return amount;

        if (fromDec < toDec) {
            uint8 diffUp = toDec - fromDec;
            while (diffUp > 0) {
                uint8 step = diffUp > 18 ? 18 : diffUp;
                amount *= _pow10(step);
                diffUp -= step;
            }
            return amount;
        }

        uint8 diffDown = fromDec - toDec;
        while (diffDown > 0) {
            uint8 step = diffDown > 18 ? 18 : diffDown;
            amount /= _pow10(step);
            diffDown -= step;
        }
        return amount;
    }

    function _pow10(uint8 k) internal pure returns (uint256 r) {
        unchecked {
            r = 1;
            for (uint8 i = 0; i < k; i++) {
                r *= 10;
            }
        }
    }
}
