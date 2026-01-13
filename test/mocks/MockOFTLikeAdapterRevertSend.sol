// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOFTLike} from "../../src/DStockComposerRouter.sol";

/// @dev OFT-like adapter that can be configured to revert on `send`.
/// Used to hit router `send2_failed` branches (try/catch).
contract MockOFTLikeAdapterRevertSend is IOFTLike {
    uint256 public fixedNativeFee;
    address public immutable tokenToLock;
    bool public revertOnSend;

    constructor(address _tokenToLock) {
        tokenToLock = _tokenToLock;
    }

    function setFee(uint256 fee) external {
        fixedNativeFee = fee;
    }

    function setRevertOnSend(bool v) external {
        revertOnSend = v;
    }

    function quoteSend(SendParam calldata, bool) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: fixedNativeFee, lzTokenFee: 0});
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address /*_refundAddress*/
    )
        external
        payable
        returns (
            bytes32 guid,
            uint64 nonce,
            MessagingFee memory fee,
            uint256 amountSentLD,
            uint256 amountReceivedLD
        )
    {
        require(msg.value >= _fee.nativeFee, "MockOFTLikeAdapterRevertSend: insufficient fee");
        if (revertOnSend) revert("MockOFTLikeAdapterRevertSend: send_reverted");

        require(IERC20(tokenToLock).transferFrom(msg.sender, address(this), _sendParam.amountLD), "lock_failed");

        guid = keccak256(abi.encodePacked(block.number, msg.sender, _sendParam.to, _sendParam.amountLD));
        nonce = uint64(block.number);
        fee = _fee;
        amountSentLD = _sendParam.amountLD;
        amountReceivedLD = _sendParam.amountLD;
    }
}

