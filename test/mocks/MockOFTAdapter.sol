// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOFTAdapter} from "../../src/interfaces/IOFTAdapter.sol";
import {IOAppCore} from "../../src/DStockUnwrapComposer.sol"; // For endpoint() interface if needed, or just mock it

contract MockOFTAdapter is IOFTAdapter {
    address public endpointAddress;
    uint256 public fixedNativeFee;

    event SendCalled(uint32 dstEid, bytes32 to, uint256 amountLD);

    constructor(address _endpoint) {
        endpointAddress = _endpoint;
    }

    function setFee(uint256 fee) external {
        fixedNativeFee = fee;
    }

    function endpoint() external view returns (address) {
        return endpointAddress;
    }

    function quoteSend(SendParam calldata _sendParam, bool) external view returns (MessagingFee memory) {
        return MessagingFee(fixedNativeFee, 0);
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address /*_refundAddress*/
    ) external payable {
        require(msg.value >= _fee.nativeFee, "MockOFT: insufficient fee");
        
        emit SendCalled(_sendParam.dstEid, _sendParam.to, _sendParam.amountLD);
    }
}
