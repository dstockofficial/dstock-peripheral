// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IOFTLike} from "../../src/DStockComposerRouter.sol";

/// @dev Minimal adapter-like OApp: `send` pulls `tokenToLock` from caller via transferFrom.
contract MockOFTLikeAdapter is IOFTLike {
    uint256 public fixedNativeFee;
    address public immutable tokenToLock;

    event SendCalled(uint32 dstEid, bytes32 to, uint256 amountLD);

    constructor(address _tokenToLock) {
        tokenToLock = _tokenToLock;
    }

    function setFee(uint256 fee) external {
        fixedNativeFee = fee;
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
        require(msg.value >= _fee.nativeFee, "MockOFTLikeAdapter: insufficient fee");
        require(IERC20(tokenToLock).transferFrom(msg.sender, address(this), _sendParam.amountLD), "lock_failed");

        emit SendCalled(_sendParam.dstEid, _sendParam.to, _sendParam.amountLD);

        guid = keccak256(abi.encodePacked(block.number, msg.sender, _sendParam.to, _sendParam.amountLD));
        nonce = uint64(block.number);
        fee = _fee;
        amountSentLD = _sendParam.amountLD;
        amountReceivedLD = _sendParam.amountLD;
    }
}

