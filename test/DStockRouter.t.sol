// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {DStockRouter} from "../src/DStockRouter.sol";
import {MockDStockWrapper} from "./mocks/MockDStockWrapper.sol";
import {MockOFTAdapter} from "./mocks/MockOFTAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IOFTAdapter} from "../src/interfaces/IOFTAdapter.sol";

contract DStockRouterTest is Test {
    DStockRouter public router;
    MockDStockWrapper public wrapper;
    MockOFTAdapter public oftAdapter;
    MockERC20 public underlying;

    uint32 constant DST_EID = 30101;
    address constant USER = address(0xCAFE);

    event WrapAndBridge(
        address indexed sender,
        address indexed underlying,
        uint256 amountIn,
        uint256 amountSentLD,
        uint32 dstEid,
        bytes32 to
    );

    function setUp() public {
        vm.deal(USER, 100 ether); // Give user ETH for fees
        wrapper = new MockDStockWrapper();
        oftAdapter = new MockOFTAdapter(address(this)); // Endpoint address doesn't matter for router
        underlying = new MockERC20("Underlying Token", "UND", 18);

        // Deploy router
        router = new DStockRouter(address(wrapper), address(oftAdapter));

        // Setup underlying in wrapper
        wrapper.setUnderlying(address(underlying), true, 18);

        // Mint tokens to user
        underlying.mint(USER, 1000e18);
    }

    function test_Constructor_RevertIf_ZeroAddress() public {
        vm.expectRevert(DStockRouter.ZeroAddress.selector);
        new DStockRouter(address(0), address(oftAdapter));

        vm.expectRevert(DStockRouter.ZeroAddress.selector);
        new DStockRouter(address(wrapper), address(0));
    }

    function test_WrapAndBridge_Success() public {
        uint256 amount = 100e18;
        bytes32 recipient = bytes32(uint256(uint160(USER)));
        uint256 nativeFee = 0.1 ether;

        oftAdapter.setFee(nativeFee);

        vm.startPrank(USER);
        underlying.approve(address(router), amount);

        // Expect calls
        // Events order:
        // 1. Transfer (underlying from user to router)
        // 2. Transfer (dStock mint to router)
        // 3. SendCalled (MockOFTAdapter)
        // 4. WrapAndBridge (Router)

        vm.expectEmit(true, true, true, true);
        emit MockOFTAdapter.SendCalled(DST_EID, recipient, amount); // amountLD = amount (18 decimals)

        vm.expectEmit(true, true, true, true);
        emit WrapAndBridge(USER, address(underlying), amount, amount, DST_EID, recipient);

        router.wrapAndBridge{value: nativeFee}(
            address(underlying),
            amount,
            DST_EID,
            recipient,
            ""
        );
        vm.stopPrank();

        // Verify balances
        assertEq(underlying.balanceOf(USER), 900e18); // 1000 - 100
        assertEq(underlying.balanceOf(address(router)), 0); // Should be spent
        // Wrapper now holds the underlying (simulated by MockDStockWrapper taking no action on transfer but minting dStock)
        // In real wrapper, it would pull from router.
        // Check router allowance to wrapper?
        // Since we mock wrapper, we need to check if wrapper received allowance?
        // Mock wrapper doesn't check allowance. But we can check Router's code path by success.
    }

    function test_WrapAndBridge_Success_RefundExess() public {
        uint256 amount = 100e18;
        bytes32 recipient = bytes32(uint256(uint160(USER)));
        uint256 nativeFee = 0.1 ether;
        uint256 sentValue = 0.5 ether;

        oftAdapter.setFee(nativeFee);

        vm.startPrank(USER);
        underlying.approve(address(router), amount);

        // Capture balance AFTER ensuring user has funds (100 ether from setUp)
        uint256 preBalance = USER.balance;

        router.wrapAndBridge{value: sentValue}(
            address(underlying),
            amount,
            DST_EID,
            recipient,
            ""
        );
        
        uint256 postBalance = USER.balance;
        // Logic: preBalance - sentValue + refund
        // refund = sentValue - nativeFee
        // post = pre - sent + (sent - fee) = pre - fee
        assertEq(postBalance, preBalance - nativeFee); 
        vm.stopPrank();
    }

    function test_WrapAndBridge_RevertIf_AmountZero() public {
        vm.expectRevert(DStockRouter.AmountZero.selector);
        router.wrapAndBridge(address(underlying), 0, DST_EID, bytes32(uint256(1)), "");
    }

    function test_WrapAndBridge_RevertIf_InvalidRecipient() public {
        vm.expectRevert(DStockRouter.InvalidRecipient.selector);
        router.wrapAndBridge(address(underlying), 100, DST_EID, bytes32(0), "");
    }

    function test_WrapAndBridge_RevertIf_UnsupportedUnderlying() public {
        address badToken = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(DStockRouter.UnsupportedUnderlying.selector, badToken));
        router.wrapAndBridge(badToken, 100, DST_EID, bytes32(uint256(1)), "");
    }

    function test_WrapAndBridge_RevertIf_InsufficientFee() public {
        uint256 amount = 100e18;
        uint256 nativeFee = 1 ether;
        oftAdapter.setFee(nativeFee);

        vm.startPrank(USER);
        underlying.approve(address(router), amount);

        vm.expectRevert(abi.encodeWithSelector(DStockRouter.InsufficientFee.selector, 0.5 ether, nativeFee));
        router.wrapAndBridge{value: 0.5 ether}(
            address(underlying),
            amount,
            DST_EID,
            bytes32(uint256(uint160(USER))),
            ""
        );
        vm.stopPrank();
    }

    function test_QuoteWrapAndBridge() public {
        uint256 amount = 100e18;
        uint256 nativeFee = 0.123 ether;
        oftAdapter.setFee(nativeFee);

        uint256 quoted = router.quoteWrapAndBridge(
            address(underlying),
            amount,
            DST_EID,
            bytes32(uint256(uint160(USER))),
            ""
        );

        assertEq(quoted, nativeFee);
    }
    
    function test_QuoteWrapAndBridge_RevertIf_AmountZero() public {
        vm.expectRevert(DStockRouter.AmountZero.selector);
        router.quoteWrapAndBridge(address(underlying), 0, DST_EID, bytes32(uint256(1)), "");
    }

    function test_QuoteWrapAndBridge_RevertIf_InvalidRecipient() public {
        vm.expectRevert(DStockRouter.InvalidRecipient.selector);
        router.quoteWrapAndBridge(address(underlying), 100, DST_EID, bytes32(0), "");
    }
}
