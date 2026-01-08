// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DStockUnwrapComposer} from "../src/DStockUnwrapComposer.sol";
import {MockDStockWrapper} from "./mocks/MockDStockWrapper.sol";
import {MockOFTAdapter} from "./mocks/MockOFTAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DStockUnwrapComposerTest is Test {
    DStockUnwrapComposer public composer;
    MockDStockWrapper public wrapper;
    MockOFTAdapter public oftAdapter;
    MockERC20 public underlying;
    address public endpoint;

    uint32 constant SRC_EID = 30102;

    event ComposedUnwrap(
        bytes32 indexed guid,
        address indexed oft,
        address indexed receiver,
        uint256 amountLD,
        uint256 amountToken
    );

    event ComposeFailed(bytes32 indexed guid, bytes reason);

    function setUp() public {
        endpoint = address(0xE11D);
        wrapper = new MockDStockWrapper();
        oftAdapter = new MockOFTAdapter(endpoint);
        underlying = new MockERC20("Underlying Token", "UND", 18);

        composer = new DStockUnwrapComposer(address(wrapper), address(underlying), address(oftAdapter));
        
        // Setup wrapper
        wrapper.setUnderlying(address(underlying), true, 18);
    }

    function test_Constructor_RevertIf_ZeroAddress() public {
        vm.expectRevert(DStockUnwrapComposer.ZeroAddress.selector);
        new DStockUnwrapComposer(address(0), address(underlying), address(oftAdapter));
        
        vm.expectRevert(DStockUnwrapComposer.ZeroAddress.selector);
        new DStockUnwrapComposer(address(wrapper), address(0), address(oftAdapter));
        
        vm.expectRevert(DStockUnwrapComposer.ZeroAddress.selector);
        new DStockUnwrapComposer(address(wrapper), address(underlying), address(0));
    }

    function test_LzCompose_Success_SameDecimals() public {
        uint256 amountLD = 100e18;
        address receiver = address(0xB0B0);
        bytes32 guid = bytes32("guid");

        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(receiver))));
        bytes32 composeFrom = bytes32(uint256(uint160(address(0xCAFE))));
        // Message format: nonce(8) + srcEid(4) + amountLD(32) + composeFrom(32) + composeMsg
        bytes memory message = abi.encodePacked(
            uint64(1), 
            uint32(SRC_EID), 
            bytes32(uint256(amountLD)), 
            composeFrom, 
            composeMsg
        );

        // Expect Transfer (Burn) first if we were checking strictly, but we can just check the final event
        // or check all.
        // MockERC20 emits Transfer(from, 0, amount) on burn.
        
        // vm.expectEmit(true, true, true, true);
        // emit MockERC20.Transfer(address(composer), address(0), amountLD);

        // Mint dStock to composer so it can burn/unwrap
        wrapper.mint(address(composer), amountLD);

        vm.expectEmit(true, true, true, true, address(composer));
        emit ComposedUnwrap(guid, address(oftAdapter), receiver, amountLD, amountLD);

        vm.prank(endpoint);
        composer.lzCompose(address(oftAdapter), guid, message, address(0), "");
    }

    function test_LzCompose_Success_ScaleDown() public {
        // Change underlying to 6 decimals
        wrapper.setUnderlying(address(underlying), true, 6);
        
        uint256 amountLD = 100e18; // 100 tokens (18 decimals)
        uint256 expectedAmountToken = 100e6; // 100 tokens (6 decimals)
        address receiver = address(0xB0B0);
        bytes32 guid = bytes32("guid");

        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(receiver))));
        bytes32 composeFrom = bytes32(uint256(uint160(address(0xCAFE))));
        bytes memory message = abi.encodePacked(
            uint64(1), 
            uint32(SRC_EID), 
            bytes32(uint256(amountLD)), 
            composeFrom, 
            composeMsg
        );

        // Mint dStock to composer
        wrapper.mint(address(composer), expectedAmountToken);

        vm.expectEmit(true, true, true, true, address(composer));
        emit ComposedUnwrap(guid, address(oftAdapter), receiver, amountLD, expectedAmountToken);

        vm.prank(endpoint);
        composer.lzCompose(address(oftAdapter), guid, message, address(0), "");
    }

    function test_LzCompose_RevertIf_NotEndpoint() public {
        vm.expectRevert(DStockUnwrapComposer.OnlyEndpoint.selector);
        composer.lzCompose(address(oftAdapter), bytes32(0), "", address(0), "");
    }

    function test_LzCompose_RevertIf_InvalidCaller() public {
        vm.prank(endpoint);
        vm.expectRevert(abi.encodeWithSelector(DStockUnwrapComposer.InvalidComposeCaller.selector, address(oftAdapter), address(0xBAD)));
        composer.lzCompose(address(0xBAD), bytes32(0), "", address(0), "");
    }

    function test_LzCompose_RevertIf_UnderlyingDisabled() public {
        wrapper.setUnderlying(address(underlying), false, 18);

        bytes memory message = _buildMessage(100e18, address(0xB0B0));

        // Reverts before try/catch
        vm.expectRevert(DStockUnwrapComposer.UnderlyingDisabled.selector);

        vm.prank(endpoint);
        composer.lzCompose(address(oftAdapter), bytes32("guid"), message, address(0), "");
    }

    function test_LzCompose_RevertIf_InvalidReceiver() public {
        // Empty compose message -> too short -> InvalidRecipient
        bytes memory message = abi.encodePacked(
            uint64(1), 
            uint32(SRC_EID), 
            bytes32(uint256(100e18)), 
            bytes32(uint256(uint160(address(0xCAFE))))
            // Missing receiver
        );

        // Reverts before try/catch in _decodeReceiver
        vm.expectRevert(DStockUnwrapComposer.InvalidRecipient.selector);

        vm.prank(endpoint);
        composer.lzCompose(address(oftAdapter), bytes32("guid"), message, address(0), "");
    }

    function test_ExecuteUnwrap_OnlySelf() public {
        vm.expectRevert(DStockUnwrapComposer.OnlySelf.selector);
        composer._executeUnwrap(100, 100, address(0xB0B0));
    }

    function _buildMessage(uint256 amount, address receiver) internal pure returns (bytes memory) {
        return abi.encodePacked(
            uint64(1), 
            uint32(SRC_EID), 
            bytes32(uint256(amount)), 
            bytes32(uint256(uint160(address(0xCAFE)))),
            bytes32(uint256(uint160(receiver)))
        );
    }
}
