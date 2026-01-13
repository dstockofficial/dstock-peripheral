// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DStockComposerRouter} from "../src/DStockComposerRouter.sol";
import {MockOFTLikeToken} from "./mocks/MockOFTLikeToken.sol";
import {MockOFTLikeAdapter} from "./mocks/MockOFTLikeAdapter.sol";
import {MockComposerWrapper} from "./mocks/MockComposerWrapper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DStockComposerRouterTest is Test {
    address internal constant ENDPOINT = address(0xE11D);
    address internal constant REFUND = address(0xBEEF);
    uint32 internal constant CHAIN_EID = 12345;

    DStockComposerRouter internal router;
    DStockComposerRouter internal impl;

    MockOFTLikeToken internal underlyingOft;
    MockComposerWrapper internal wrapper;
    MockOFTLikeAdapter internal shareAdapter;
    MockERC20 internal localUnderlying;

    event RouteFailed(bytes32 indexed guid, string reason, address refundBsc, uint256 amountLD);

    function setUp() public {
        // deploy implementation + proxy and initialize
        impl = new DStockComposerRouter();
        bytes memory initData = abi.encodeCall(DStockComposerRouter.initialize, (ENDPOINT, CHAIN_EID, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = DStockComposerRouter(payable(address(proxy)));

        // build one asset config
        underlyingOft = new MockOFTLikeToken("UnderlyingOFT", "uOFT", 6);
        localUnderlying = new MockERC20("Local Underlying", "LUND", 6);
        wrapper = new MockComposerWrapper();
        wrapper.setUnderlyingDecimals(address(underlyingOft), 6);
        wrapper.setUnderlyingDecimals(address(localUnderlying), 6);

        shareAdapter = new MockOFTLikeAdapter(address(wrapper));

        router.setRouteConfig(address(underlyingOft), address(wrapper), address(shareAdapter));
        router.setRouteConfig(address(localUnderlying), address(wrapper), address(shareAdapter));
    }

    function _compose(bytes32 guid, uint256 amountLD, bytes memory inner) internal pure returns (bytes32, bytes memory) {
        bytes memory msg_ = abi.encodePacked(uint64(1), uint32(1), bytes32(uint256(amountLD)), bytes32(uint256(0)), inner);
        return (guid, msg_);
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert();
        router.initialize(ENDPOINT, CHAIN_EID, address(this));
    }

    function test_initialize_revertIfZeroEndpointOrOwner() public {
        DStockComposerRouter i = new DStockComposerRouter();
        vm.expectRevert(DStockComposerRouter.ZeroAddress.selector);
        i.initialize(address(0), CHAIN_EID, address(this));

        i = new DStockComposerRouter();
        vm.expectRevert(DStockComposerRouter.ZeroAddress.selector);
        i.initialize(ENDPOINT, CHAIN_EID, address(0));
    }

    function test_registryMappings_written() public view {
        assertEq(router.underlyingToWrapper(address(underlyingOft)), address(wrapper));
        assertEq(router.underlyingToShareAdapter(address(underlyingOft)), address(shareAdapter));
        assertEq(router.shareAdapterToWrapper(address(shareAdapter)), address(wrapper));
    }

    function test_wrapAndBridge_user_success() public {
        address user = address(0xCAFE);
        uint256 amount = 100e6;
        uint256 expectedShares = amount * 1e12; // 6 -> 18

        localUnderlying.mint(user, amount);
        shareAdapter.setFee(0.1 ether);
        vm.deal(user, 1 ether);

        vm.startPrank(user);
        localUnderlying.approve(address(router), amount);

        uint256 sent = router.wrapAndBridge{value: 0.1 ether}(
            address(localUnderlying),
            amount,
            30367,
            bytes32(uint256(uint160(address(0xB0B)))) ,
            ""
        );
        vm.stopPrank();

        assertEq(sent, expectedShares);
        assertEq(wrapper.balanceOf(address(shareAdapter)), expectedShares);
    }

    function test_wrapAndBridge_user_refundExcessNative() public {
        address user = address(0xCAFE);
        uint256 amount = 10e6;

        localUnderlying.mint(user, amount);
        shareAdapter.setFee(0.1 ether);
        vm.deal(user, 1 ether);

        vm.startPrank(user);
        localUnderlying.approve(address(router), amount);

        uint256 pre = user.balance;
        router.wrapAndBridge{value: 0.5 ether}(address(localUnderlying), amount, 30367, bytes32(uint256(uint160(user))), "");
        uint256 post = user.balance;
        assertEq(post, pre - 0.1 ether);
        vm.stopPrank();
    }

    function test_wrapAndBridge_revertIfInvalidUnderlyingConfig() public {
        vm.expectRevert(DStockComposerRouter.InvalidOApp.selector);
        router.wrapAndBridge(address(0xBADD), 1, 30367, bytes32(uint256(1)), "");
    }

    function test_wrapAndBridge_revertIfAmountZero() public {
        vm.expectRevert(DStockComposerRouter.AmountZero.selector);
        router.wrapAndBridge(address(localUnderlying), 0, 30367, bytes32(uint256(1)), "");
    }

    function test_wrapAndBridge_revertIfInvalidRecipient() public {
        vm.expectRevert(DStockComposerRouter.InvalidRecipient.selector);
        router.wrapAndBridge(address(localUnderlying), 1, 30367, bytes32(0), "");
    }

    function test_wrapAndBridge_revertIfInsufficientFee() public {
        address user = address(0xCAFE);
        uint256 amount = 10e6;

        localUnderlying.mint(user, amount);
        shareAdapter.setFee(1 ether);
        vm.deal(user, 1 ether);

        vm.startPrank(user);
        localUnderlying.approve(address(router), amount);
        vm.expectRevert(abi.encodeWithSelector(DStockComposerRouter.InsufficientFee.selector, 0.5 ether, 1 ether));
        router.wrapAndBridge{value: 0.5 ether}(address(localUnderlying), amount, 30367, bytes32(uint256(uint160(user))), "");
        vm.stopPrank();
    }

    function test_quoteWrapAndBridge_matchesFee() public {
        shareAdapter.setFee(0.123 ether);
        uint256 fee = router.quoteWrapAndBridge(
            address(localUnderlying),
            50e6,
            30367,
            bytes32(uint256(uint160(address(0xB0B)))),
            ""
        );
        assertEq(fee, 0.123 ether);
    }

    function test_quoteWrapAndBridge_revertIfAmountZero() public {
        vm.expectRevert(DStockComposerRouter.AmountZero.selector);
        router.quoteWrapAndBridge(address(localUnderlying), 0, 30367, bytes32(uint256(1)), "");
    }

    function test_quoteWrapAndBridge_revertIfInvalidRecipient() public {
        vm.expectRevert(DStockComposerRouter.InvalidRecipient.selector);
        router.quoteWrapAndBridge(address(localUnderlying), 1, 30367, bytes32(0), "");
    }

    function test_lzCompose_revertIfNotEndpoint() public {
        vm.expectRevert(DStockComposerRouter.NotEndpoint.selector);
        router.lzCompose(address(underlyingOft), bytes32("guidNE"), "", address(0), "");
    }

    function test_lzCompose_revertIfInvalidOApp() public {
        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(1)), refundBsc: REFUND, minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guidBad"), 1, abi.encode(r));

        vm.prank(ENDPOINT);
        vm.expectRevert(DStockComposerRouter.InvalidOApp.selector);
        router.lzCompose(address(0xBADD), bytes32("guidBad"), message, address(0), "");
    }

    function test_lzCompose_forward_success() public {
        uint256 amountUnderlying = 1000e6;
        uint256 expectedShares = amountUnderlying * 1e12; // 6 -> 18

        // simulate OFT credit: underlying tokens are already on router
        underlyingOft.mint(address(router), amountUnderlying);

        // fund router to pay 2nd-hop fee
        shareAdapter.setFee(0.1 ether);
        vm.deal(address(router), 1 ether);

        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(uint160(address(0xCAFE)))), refundBsc: REFUND, minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guid1"), amountUnderlying, abi.encode(r));

        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guid1"), message, address(0), "");

        // wrapper now holds underlying; adapter now holds shares
        assertEq(underlyingOft.balanceOf(address(router)), 0);
        assertEq(underlyingOft.balanceOf(address(wrapper)), amountUnderlying);
        assertEq(wrapper.balanceOf(address(shareAdapter)), expectedShares);
        assertEq(wrapper.balanceOf(address(router)), 0);
    }

    // pause behavior removed in minimal-mapping router

    function test_lzCompose_guid_idempotent_doesNotDoubleProcess() public {
        uint256 amountUnderlying = 100e6;
        uint256 expectedShares = amountUnderlying * 1e12;

        underlyingOft.mint(address(router), amountUnderlying);
        shareAdapter.setFee(0.1 ether);
        vm.deal(address(router), 1 ether);

        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(uint160(address(0xCAFE)))), refundBsc: REFUND, minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guid3"), amountUnderlying, abi.encode(r));

        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guid3"), message, address(0), "");

        uint256 sharesAfterFirst = wrapper.balanceOf(address(shareAdapter));
        assertEq(sharesAfterFirst, expectedShares);

        // second call with same guid should no-op
        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guid3"), message, address(0), "");

        assertEq(wrapper.balanceOf(address(shareAdapter)), sharesAfterFirst);
    }

    function test_lzCompose_reverse_success() public {
        // Give wrapper underlying liquidity to return on unwrap
        uint256 underlyingLiquidity = 2000e6;
        underlyingOft.mint(address(wrapper), underlyingLiquidity);

        // Credit router shares as if shareAdapter delivered them
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        // fund router to pay 2nd-hop fee for underlyingOft.send
        underlyingOft.setFee(0.05 ether);
        vm.deal(address(router), 1 ether);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: REFUND,
            unwrapBps: 10_000,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });

        (, bytes memory message) = _compose(bytes32("guid4"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guid4"), message, address(0), "");

        // shares should be burned from router during unwrap, underlying burned during send
        assertEq(wrapper.balanceOf(address(router)), 0);
        assertEq(underlyingOft.balanceOf(address(router)), 0);
    }

    function test_lzCompose_reverse_deliverLocal_whenFinalDstIsChainEid() public {
        address receiver = address(0xCAFE);

        // Give wrapper underlying liquidity to return on unwrap
        uint256 underlyingLiquidity = 2000e6;
        underlyingOft.mint(address(wrapper), underlyingLiquidity);

        // Credit router shares as if shareAdapter delivered them
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: CHAIN_EID,
            finalTo: bytes32(uint256(uint160(receiver))),
            refundBsc: REFUND,
            unwrapBps: 10_000,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });

        (, bytes memory message) = _compose(bytes32("guidLocal"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidLocal"), message, address(0), "");

        // Delivered locally: receiver got underlying, router holds none
        assertEq(wrapper.balanceOf(address(router)), 0);
        assertEq(underlyingOft.balanceOf(address(router)), 0);
        assertGt(underlyingOft.balanceOf(receiver), 0);
    }

    function test_lzCompose_reverse_receiverZero_emitsRouteFailedAndRefundsUnderlying() public {
        // Liquidity for unwrap
        underlyingOft.mint(address(wrapper), 2000e6);

        // Credit router shares as if shareAdapter delivered them
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: CHAIN_EID,
            finalTo: bytes32(0), // receiver == address(0)
            refundBsc: REFUND,
            unwrapBps: 10_000,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });

        (, bytes memory message) = _compose(bytes32("guidRecv0"), sharesIn, abi.encode(rr));

        vm.expectEmit(true, true, true, true);
        emit RouteFailed(bytes32("guidRecv0"), "receiver_zero", REFUND, 1000e6);

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidRecv0"), message, address(0), "");

        // underlying refunded to refund address (shares already burned by unwrap)
        assertEq(underlyingOft.balanceOf(REFUND), 1000e6);
    }

    function test_lzCompose_reverse_unwrapFails_refundsShares() public {
        // Use a token the wrapper doesn't support (decimals not configured), so unwrap will revert and router refunds shares.
        MockOFTLikeToken badUnderlying = new MockOFTLikeToken("Bad", "BAD", 6);

        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(badUnderlying),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(1)),
            refundBsc: REFUND,
            unwrapBps: 10_000,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidUnwrapFail"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidUnwrapFail"), message, address(0), "");

        // shares refunded to refundBsc
        assertEq(wrapper.balanceOf(REFUND), sharesIn);
    }
}

