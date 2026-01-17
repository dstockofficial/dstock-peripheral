// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DStockComposerRouter} from "../src/DStockComposerRouter.sol";
import {MockOFTLikeToken} from "./mocks/MockOFTLikeToken.sol";
import {MockOFTLikeAdapter} from "./mocks/MockOFTLikeAdapter.sol";
import {MockOFTLikeAdapterRevertSend} from "./mocks/MockOFTLikeAdapterRevertSend.sol";
import {MockOFTLikeTokenRevertSend} from "./mocks/MockOFTLikeTokenRevertSend.sol";
import {MockComposerWrapperZeroShares} from "./mocks/MockComposerWrapperZeroShares.sol";
import {MockComposerWrapper} from "./mocks/MockComposerWrapper.sol";
import {MockComposerWrapperNoOpUnwrap} from "./mocks/MockComposerWrapperNoOpUnwrap.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC20Blocklist} from "./mocks/MockERC20Blocklist.sol";
import {MockWETH9} from "./mocks/MockWETH9.sol";
import {WrappedNativePayoutHelper} from "../src/WrappedNativePayoutHelper.sol";

contract RejectEther {
    receive() external payable {
        revert("no_eth");
    }
}

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
    MockWETH9 internal wnative;

    event RouteFailed(bytes32 indexed guid, string reason, address refundBsc, uint256 amountLD);
    event RefundFailed(bytes32 indexed guid, address indexed token, address indexed refundBsc, uint256 amount);

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

        // wrapped native setup: native -> wnative -> wrapper -> shareAdapter
        wnative = new MockWETH9();
        wrapper.setUnderlyingDecimals(address(wnative), 18);
        router.setWrappedNative(address(wnative));
        router.setWrappedNativePayoutHelper(address(new WrappedNativePayoutHelper()));
        router.setRouteConfig(address(wnative), address(wrapper), address(shareAdapter));
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

    function test_setRouteConfig_onlyOwner() public {
        vm.prank(address(0xA11CE));
        vm.expectRevert();
        router.setRouteConfig(address(0x1234), address(wrapper), address(shareAdapter));
    }

    function test_setRouteConfig_revertIfZeroWrapperOrAdapter() public {
        vm.expectRevert(DStockComposerRouter.ZeroAddress.selector);
        router.setRouteConfig(address(underlyingOft), address(0), address(shareAdapter));

        vm.expectRevert(DStockComposerRouter.ZeroAddress.selector);
        router.setRouteConfig(address(underlyingOft), address(wrapper), address(0));
    }

    function test_setRouteConfig_underlyingZero_onlySetsReverseMapping() public {
        MockOFTLikeAdapter a = new MockOFTLikeAdapter(address(wrapper));
        router.setRouteConfig(address(0), address(wrapper), address(a));

        assertEq(router.shareAdapterToWrapper(address(a)), address(wrapper));
        assertEq(router.underlyingToWrapper(address(0)), address(0));
        assertEq(router.underlyingToShareAdapter(address(0)), address(0));
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
            "",
            expectedShares
        );
        vm.stopPrank();

        assertEq(sent, expectedShares);
        assertEq(wrapper.balanceOf(address(shareAdapter)), expectedShares);
        assertEq(wrapper.allowance(address(router), address(shareAdapter)), 0);
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
        router.wrapAndBridge{value: 0.5 ether}(address(localUnderlying), amount, 30367, bytes32(uint256(uint160(user))), "", 0);
        uint256 post = user.balance;
        assertEq(post, pre - 0.1 ether);
        vm.stopPrank();
    }

    function test_setWrappedNative_onlyOwner() public {
        vm.prank(address(0xA11CE));
        vm.expectRevert();
        router.setWrappedNative(address(0x1));
    }

    function test_setWrappedNative_revertIfZero() public {
        vm.expectRevert(DStockComposerRouter.ZeroAddress.selector);
        router.setWrappedNative(address(0));
    }

    function test_wrapAndBridgeNative_revertIfWrappedNativeNotSet() public {
        // fresh router without wrappedNative configured
        DStockComposerRouter i = new DStockComposerRouter();
        bytes memory initData = abi.encodeCall(DStockComposerRouter.initialize, (ENDPOINT, CHAIN_EID, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(i), initData);
        DStockComposerRouter r2 = DStockComposerRouter(payable(address(proxy)));

        vm.expectRevert(DStockComposerRouter.WrappedNativeNotSet.selector);
        r2.wrapAndBridgeNative{value: 1}(1, 30367, bytes32(uint256(1)), "", 0);
    }

    function test_wrapAndBridgeNative_success_andRefundsExcessFee() public {
        address user = address(0xCAFE);
        uint256 amountNative = 1 ether;

        shareAdapter.setFee(0.1 ether);
        vm.deal(user, 2 ether);

        uint256 pre = user.balance;
        vm.prank(user);
        uint256 sharesSent =
            router.wrapAndBridgeNative{value: 1.5 ether}(amountNative, 30367, bytes32(uint256(uint160(user))), "", amountNative);

        // wrapper mints shares 1:1 for 18-decimal underlying
        assertEq(sharesSent, amountNative);
        assertEq(wrapper.allowance(address(router), address(shareAdapter)), 0);
        // net cost = amountNative + fee (refund excess fee)
        assertEq(user.balance, pre - 1.1 ether);
    }

    function test_wrapAndBridgeNative_revertIfMsgValueLessThanAmountNative() public {
        address user = address(0xCAFE);
        vm.deal(user, 1 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(DStockComposerRouter.InsufficientFee.selector, 0.5 ether, 1 ether));
        router.wrapAndBridgeNative{value: 0.5 ether}(1 ether, 30367, bytes32(uint256(1)), "", 0);
    }

    function test_wrapAndBridgeNative_revertIfInsufficientFeeForSend() public {
        address user = address(0xCAFE);
        uint256 amountNative = 1 ether;
        shareAdapter.setFee(0.2 ether);

        vm.deal(user, 2 ether);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(DStockComposerRouter.InsufficientFee.selector, 0.05 ether, 0.2 ether));
        router.wrapAndBridgeNative{value: 1.05 ether}(amountNative, 30367, bytes32(uint256(1)), "", 0);
    }

    function test_wrapAndBridgeNative_revertIfInvalidOAppConfig() public {
        // fresh router: wrappedNative set, but no setRouteConfig for it
        DStockComposerRouter i = new DStockComposerRouter();
        bytes memory initData = abi.encodeCall(DStockComposerRouter.initialize, (ENDPOINT, CHAIN_EID, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(i), initData);
        DStockComposerRouter r2 = DStockComposerRouter(payable(address(proxy)));

        MockWETH9 w2 = new MockWETH9();
        r2.setWrappedNative(address(w2));

        vm.expectRevert(DStockComposerRouter.InvalidOApp.selector);
        r2.wrapAndBridgeNative{value: 1 ether}(1 ether, 30367, bytes32(uint256(1)), "", 0);
    }

    function test_lzCompose_reverse_deliverLocal_native_whenUnderlyingIsWrappedNative() public {
        address receiver = address(0xCAFE);

        // provide wrapped-native liquidity to wrapper
        uint256 liquidity = 2000 ether;
        vm.deal(address(wrapper), liquidity);
        vm.prank(address(wrapper));
        wnative.deposit{value: liquidity}();

        // credit router shares
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(wnative),
            finalDstEid: CHAIN_EID,
            finalTo: bytes32(uint256(uint160(receiver))),
            refundBsc: REFUND,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidNativeOk"), sharesIn, abi.encode(rr));

        uint256 pre = receiver.balance;
        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidNativeOk"), message, address(0), "");

        assertEq(receiver.balance, pre + sharesIn);
        assertEq(wnative.balanceOf(receiver), 0);
        assertEq(wnative.balanceOf(address(router)), 0);
    }

    function test_lzCompose_reverse_deliverLocal_native_fail_refundsWrappedNative() public {
        RejectEther reject = new RejectEther();
        address receiver = address(reject);

        // provide wrapped-native liquidity to wrapper
        uint256 liquidity = 2000 ether;
        vm.deal(address(wrapper), liquidity);
        vm.prank(address(wrapper));
        wnative.deposit{value: liquidity}();

        // credit router shares
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(wnative),
            finalDstEid: CHAIN_EID,
            finalTo: bytes32(uint256(uint160(receiver))),
            refundBsc: REFUND,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidNativeFail"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidNativeFail"), message, address(0), "");

        // native send failed; wrapped token refunded to refund address
        assertEq(REFUND.balance, 0);
        assertEq(wnative.balanceOf(REFUND), sharesIn);
        assertEq(receiver.balance, 0);
    }

    function test_wrapAndBridge_revertIfInvalidUnderlyingConfig() public {
        vm.expectRevert(DStockComposerRouter.InvalidOApp.selector);
        router.wrapAndBridge(address(0xBADD), 1, 30367, bytes32(uint256(1)), "", 0);
    }

    function test_wrapAndBridge_revertIfAmountZero() public {
        vm.expectRevert(DStockComposerRouter.AmountZero.selector);
        router.wrapAndBridge(address(localUnderlying), 0, 30367, bytes32(uint256(1)), "", 0);
    }

    function test_wrapAndBridge_revertIfInvalidRecipient() public {
        vm.expectRevert(DStockComposerRouter.InvalidRecipient.selector);
        router.wrapAndBridge(address(localUnderlying), 1, 30367, bytes32(0), "", 0);
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
        router.wrapAndBridge{value: 0.5 ether}(address(localUnderlying), amount, 30367, bytes32(uint256(uint160(user))), "", 0);
        vm.stopPrank();
    }

    function test_wrapAndBridge_revertIfInsufficientAmount() public {
        address user = address(0xCAFE);
        uint256 amount = 10e6; // 6 decimals
        uint256 expectedSentLD = amount * 1e12; // scaled to 18 decimals by MockComposerWrapper

        localUnderlying.mint(user, amount);
        shareAdapter.setFee(0);
        vm.deal(user, 1 ether);

        vm.startPrank(user);
        localUnderlying.approve(address(router), amount);
        vm.expectRevert(
            abi.encodeWithSelector(DStockComposerRouter.InsufficientAmount.selector, expectedSentLD, expectedSentLD + 1)
        );
        router.wrapAndBridge(address(localUnderlying), amount, 30367, bytes32(uint256(uint160(user))), "", expectedSentLD + 1);
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

    function test_quoteWrapAndBridge_revertIfPreviewWrapReturnsZero() public {
        // wrapper.previewWrap returns 0 if decimals not configured
        MockERC20 u = new MockERC20("U", "U", 6);
        router.setRouteConfig(address(u), address(wrapper), address(shareAdapter));

        vm.expectRevert(DStockComposerRouter.AmountZero.selector);
        router.quoteWrapAndBridge(address(u), 1e6, 30367, bytes32(uint256(1)), "");
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

    function test_lzCompose_forward_decodeRouteFailed_emitsRouteFailed() public {
        uint256 amountUnderlying = 100e6;
        underlyingOft.mint(address(router), amountUnderlying);

        (, bytes memory message) = _compose(bytes32("guidDecodeFwd"), amountUnderlying, hex"deadbeef");

        vm.expectEmit(true, true, true, true);
        emit RouteFailed(bytes32("guidDecodeFwd"), "decode_route_failed", address(0), amountUnderlying);

        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guidDecodeFwd"), message, address(0), "");
    }

    function test_lzCompose_forward_refundZero_emitsRouteFailed_andKeepsUnderlying() public {
        uint256 amountUnderlying = 100e6;
        underlyingOft.mint(address(router), amountUnderlying);

        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(1)), refundBsc: address(0), minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guidRefund0Fwd"), amountUnderlying, abi.encode(r));

        vm.expectEmit(true, true, true, true);
        emit RouteFailed(bytes32("guidRefund0Fwd"), "refund_zero", address(0), amountUnderlying);

        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guidRefund0Fwd"), message, address(0), "");

        // no wrapping attempted
        assertEq(underlyingOft.balanceOf(address(router)), amountUnderlying);
    }

    function test_lzCompose_forward_feeInsufficient_refundsSharesToRefundBsc() public {
        uint256 amountUnderlying = 10e6;
        uint256 expectedShares = amountUnderlying * 1e12;

        underlyingOft.mint(address(router), amountUnderlying);
        shareAdapter.setFee(1 ether); // router has 0 ether => fee insufficient

        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(1)), refundBsc: REFUND, minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guidFeeFwd"), amountUnderlying, abi.encode(r));

        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guidFeeFwd"), message, address(0), "");

        // shares refunded to refundBsc
        assertEq(wrapper.balanceOf(REFUND), expectedShares);
        assertEq(wrapper.balanceOf(address(router)), 0);
    }

    function test_lzCompose_forward_sendReverts_refundsSharesToRefundBsc() public {
        uint256 amountUnderlying = 10e6;
        uint256 expectedShares = amountUnderlying * 1e12;

        underlyingOft.mint(address(router), amountUnderlying);

        // Configure a shareAdapter that reverts on send
        MockOFTLikeAdapterRevertSend badAdapter = new MockOFTLikeAdapterRevertSend(address(wrapper));
        badAdapter.setFee(0);
        badAdapter.setRevertOnSend(true);
        router.setRouteConfig(address(underlyingOft), address(wrapper), address(badAdapter));

        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(1)), refundBsc: REFUND, minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guidSendFailFwd"), amountUnderlying, abi.encode(r));

        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guidSendFailFwd"), message, address(0), "");

        assertEq(wrapper.balanceOf(REFUND), expectedShares);
        assertEq(wrapper.balanceOf(address(router)), 0);
        assertEq(wrapper.allowance(address(router), address(badAdapter)), 0);
    }

    function test_lzCompose_forward_refundsLeftoverNativeToRefundBsc() public {
        uint256 amountUnderlying = 10e6;
        underlyingOft.mint(address(router), amountUnderlying);

        shareAdapter.setFee(0.1 ether);

        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(1)), refundBsc: REFUND, minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guidRefundNativeFwd"), amountUnderlying, abi.encode(r));

        vm.deal(ENDPOINT, 1 ether);
        uint256 preRefund = REFUND.balance;

        vm.prank(ENDPOINT);
        router.lzCompose{value: 0.5 ether}(address(underlyingOft), bytes32("guidRefundNativeFwd"), message, address(0), "");

        // 0.1 is spent on send; 0.4 is refunded (best-effort)
        assertEq(REFUND.balance, preRefund + 0.4 ether);
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

    function test_lzCompose_forward_wrapZeroShares_underlyingSpent_doesNotOverRefund() public {
        uint256 amountUnderlying = 10e6;

        // Router has MORE underlying than the credited amount, so an over-refund would drain router funds.
        underlyingOft.mint(address(router), amountUnderlying * 2);

        // Wrapper consumes underlying but mints 0 shares (rounding-to-zero scenario)
        MockComposerWrapperZeroShares z = new MockComposerWrapperZeroShares();
        router.setRouteConfig(address(underlyingOft), address(z), address(shareAdapter));

        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(1)), refundBsc: REFUND, minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guidWrapZeroUnderlyingSpent"), amountUnderlying, abi.encode(r));

        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guidWrapZeroUnderlyingSpent"), message, address(0), "");

        // Wrapper pulled only the credited amount; router keeps its remaining balance (no over-refund).
        assertEq(underlyingOft.balanceOf(address(z)), amountUnderlying);
        assertEq(underlyingOft.balanceOf(address(router)), amountUnderlying);
        assertEq(underlyingOft.balanceOf(REFUND), 0);
        assertEq(underlyingOft.allowance(address(router), address(z)), 0);
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

    function test_lzCompose_reverse_decodeReverseFailed_emitsRouteFailed() public {
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        (, bytes memory message) = _compose(bytes32("guidDecodeRev"), sharesIn, hex"deadbeef");

        vm.expectEmit(true, true, true, true);
        emit RouteFailed(bytes32("guidDecodeRev"), "decode_reverse_route_failed", address(0), sharesIn);

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidDecodeRev"), message, address(0), "");
    }

    function test_lzCompose_reverse_refundZero_emitsRouteFailed() public {
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: address(0),
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidRefund0Rev"), sharesIn, abi.encode(rr));

        vm.expectEmit(true, true, true, true);
        emit RouteFailed(bytes32("guidRefund0Rev"), "refund_zero", address(0), sharesIn);

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidRefund0Rev"), message, address(0), "");
    }

    function test_lzCompose_reverse_underlyingZero_refundsShares() public {
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(0),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: REFUND,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidUnder0"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidUnder0"), message, address(0), "");

        assertEq(wrapper.balanceOf(REFUND), sharesIn);
    }

    function test_lzCompose_reverse_insufficientShares_emitsRefundFailed() public {
        uint256 sharesIn = 1000e18;
        // router has 0 shares; refund attempt will fail and emit RefundFailed

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: REFUND,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidNoShares"), sharesIn, abi.encode(rr));

        vm.expectEmit(true, true, true, true);
        emit RefundFailed(bytes32("guidNoShares"), address(wrapper), REFUND, sharesIn);

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidNoShares"), message, address(0), "");
    }

    function test_lzCompose_reverse_unwrapZeroOut_refundsShares() public {
        // Use wrapper whose unwrap is a no-op so underlyingOut == 0 and shares can still be refunded.
        MockComposerWrapperNoOpUnwrap w = new MockComposerWrapperNoOpUnwrap();
        MockOFTLikeAdapter a = new MockOFTLikeAdapter(address(w));
        router.setRouteConfig(address(0), address(w), address(a)); // reverse mapping for adapter
        w.setUnderlyingDecimals(address(underlyingOft), 6);

        uint256 sharesIn = 1000e18;
        w.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: REFUND,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidZeroOut"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(a), bytes32("guidZeroOut"), message, address(0), "");

        assertEq(w.balanceOf(REFUND), sharesIn);
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

    function test_lzCompose_reverse_local_underlyingBelowMin_refundsUnderlying() public {
        address receiver = address(0xCAFE);

        underlyingOft.mint(address(wrapper), 2000e6);
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: CHAIN_EID,
            finalTo: bytes32(uint256(uint160(receiver))),
            refundBsc: REFUND,
            minAmountLD2: 2000e6, // larger than unwrapped amount
            extraOptions2: "",
            composeMsg2: ""
        });

        (, bytes memory message) = _compose(bytes32("guidMinLocal"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidMinLocal"), message, address(0), "");

        // receiver got nothing; refund got underlying
        assertEq(underlyingOft.balanceOf(receiver), 0);
        assertEq(underlyingOft.balanceOf(REFUND), 1000e6);
    }

    function test_lzCompose_reverse_local_deliverFailed_refundsUnderlying() public {
        address receiver = address(0xCAFE);

        MockERC20Blocklist bad = new MockERC20Blocklist("Bad", "BAD", 6);
        bad.setBlockedRecipient(receiver);
        wrapper.setUnderlyingDecimals(address(bad), 6);

        // provide liquidity to wrapper
        bad.mint(address(wrapper), 2000e6);

        // credit shares to router
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(bad),
            finalDstEid: CHAIN_EID,
            finalTo: bytes32(uint256(uint160(receiver))),
            refundBsc: REFUND,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });

        (, bytes memory message) = _compose(bytes32("guidDeliverFail"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidDeliverFail"), message, address(0), "");

        // delivery to receiver failed => refunded to refundBsc
        assertEq(bad.balanceOf(receiver), 0);
        assertEq(bad.balanceOf(REFUND), 1000e6);
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

    function test_lzCompose_reverse_crosschain_underlyingBelowMin_refundsUnderlying() public {
        underlyingOft.mint(address(wrapper), 2000e6);
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: REFUND,
            minAmountLD2: 2000e6, // larger than unwrapped amount
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidMinX"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidMinX"), message, address(0), "");

        assertEq(underlyingOft.balanceOf(REFUND), 1000e6);
    }

    function test_lzCompose_reverse_crosschain_feeInsufficient_refundsUnderlying() public {
        underlyingOft.mint(address(wrapper), 2000e6);
        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        underlyingOft.setFee(1 ether); // router has 0 ether => fee insufficient

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: REFUND,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidFeeX"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidFeeX"), message, address(0), "");

        assertEq(underlyingOft.balanceOf(REFUND), 1000e6);
    }

    function test_lzCompose_reverse_crosschain_sendReverts_refundsUnderlying() public {
        MockOFTLikeTokenRevertSend u = new MockOFTLikeTokenRevertSend("Revert", "R", 6);
        u.setFee(0);
        u.setRevertOnSend(true);
        wrapper.setUnderlyingDecimals(address(u), 6);

        // wrapper liquidity for unwrap
        u.mint(address(wrapper), 2000e6);

        uint256 sharesIn = 1000e18;
        wrapper.mintShares(address(router), sharesIn);

        // fund router not necessary since fee=0
        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(u),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: REFUND,
            minAmountLD2: 0,
            extraOptions2: "",
            composeMsg2: ""
        });
        (, bytes memory message) = _compose(bytes32("guidSendX"), sharesIn, abi.encode(rr));

        vm.prank(ENDPOINT);
        router.lzCompose(address(shareAdapter), bytes32("guidSendX"), message, address(0), "");

        // send reverted => refunded underlying
        assertEq(u.balanceOf(REFUND), 1000e6);
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

    function test_decodeHelpers_workAndRevert() public {
        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(1)), refundBsc: REFUND, minAmountLD2: 7});
        DStockComposerRouter.RouteMsg memory r2 = router._decodeRouteMsg(abi.encode(r));
        assertEq(r2.finalDstEid, r.finalDstEid);
        assertEq(r2.finalTo, r.finalTo);
        assertEq(r2.refundBsc, r.refundBsc);
        assertEq(r2.minAmountLD2, r.minAmountLD2);

        DStockComposerRouter.ReverseRouteMsg memory rr = DStockComposerRouter.ReverseRouteMsg({
            underlying: address(underlyingOft),
            finalDstEid: 40168,
            finalTo: bytes32(uint256(123)),
            refundBsc: REFUND,
            minAmountLD2: 9,
            extraOptions2: hex"01",
            composeMsg2: hex"02"
        });
        DStockComposerRouter.ReverseRouteMsg memory rr2 = router._decodeReverseRouteMsg(abi.encode(rr));
        assertEq(rr2.underlying, rr.underlying);
        assertEq(rr2.finalDstEid, rr.finalDstEid);
        assertEq(rr2.finalTo, rr.finalTo);
        assertEq(rr2.refundBsc, rr.refundBsc);
        assertEq(rr2.minAmountLD2, rr.minAmountLD2);
        assertEq(rr2.extraOptions2, rr.extraOptions2);
        assertEq(rr2.composeMsg2, rr.composeMsg2);

        vm.expectRevert();
        router._decodeRouteMsg(hex"deadbeef");

        vm.expectRevert();
        router._decodeReverseRouteMsg(hex"deadbeef");
    }

    function test_rescueToken_onlyOwner_andTransfers() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        t.mint(address(router), 123);

        address to = address(0xCAFE);
        router.rescueToken(address(t), to, 123);
        assertEq(t.balanceOf(to), 123);

        // non-owner
        t.mint(address(router), 1);
        vm.prank(address(0xA11CE));
        vm.expectRevert();
        router.rescueToken(address(t), to, 1);
    }

    function test_rescueNative_onlyOwner_andTransfers() public {
        vm.deal(address(router), 1 ether);

        address to = address(0xCAFE);
        uint256 pre = to.balance;
        router.rescueNative(to, 0.4 ether);
        assertEq(to.balance, pre + 0.4 ether);

        vm.prank(address(0xA11CE));
        vm.expectRevert();
        router.rescueNative(to, 0.1 ether);
    }

    function test_upgradeToAndCall_onlyOwner() public {
        DStockComposerRouter newImpl = new DStockComposerRouter();

        vm.prank(address(0xA11CE));
        vm.expectRevert();
        router.upgradeToAndCall(address(newImpl), "");

        // owner upgrade should succeed
        router.upgradeToAndCall(address(newImpl), "");
    }
}

