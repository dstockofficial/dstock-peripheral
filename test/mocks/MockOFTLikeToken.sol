// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IOFTLike} from "../../src/DStockComposerRouter.sol";

/// @dev ERC20 token that also behaves like a minimal OFT: `send` burns from the caller.
contract MockOFTLikeToken is ERC20, IOFTLike {
    uint256 public fixedNativeFee;
    event SendCalled(uint32 dstEid, bytes32 to, uint256 amountLD);

    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
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
        require(msg.value >= _fee.nativeFee, "MockOFTLikeToken: insufficient fee");

        // emulate OFT debit on destination by burning from caller
        _burn(msg.sender, _sendParam.amountLD);

        emit SendCalled(_sendParam.dstEid, _sendParam.to, _sendParam.amountLD);

        guid = keccak256(abi.encodePacked(block.number, msg.sender, _sendParam.to, _sendParam.amountLD));
        nonce = uint64(block.number);
        fee = _fee;
        amountSentLD = _sendParam.amountLD;
        amountReceivedLD = _sendParam.amountLD;
    }
}

