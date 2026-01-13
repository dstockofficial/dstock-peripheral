// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DStockComposerRouter} from "../src/DStockComposerRouter.sol";
import {MockOFTLikeToken} from "./mocks/MockOFTLikeToken.sol";
import {MockOFTLikeAdapter} from "./mocks/MockOFTLikeAdapter.sol";
import {MockComposerWrapper} from "./mocks/MockComposerWrapper.sol";

contract DStockComposerRouterTest is Test {
    address internal constant ENDPOINT = address(0xE11D);
    address internal constant REFUND = address(0xBEEF);

    DStockComposerRouter internal router;
    DStockComposerRouter internal impl;

    MockOFTLikeToken internal underlyingOft;
    MockComposerWrapper internal wrapper;
    MockOFTLikeAdapter internal shareAdapter;

    bytes32 internal configId;

    function setUp() public {
        // deploy implementation + proxy and initialize
        impl = new DStockComposerRouter();
        bytes memory initData = abi.encodeCall(DStockComposerRouter.initialize, (ENDPOINT, address(this)));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        router = DStockComposerRouter(payable(address(proxy)));

        // build one asset config
        underlyingOft = new MockOFTLikeToken("UnderlyingOFT", "uOFT", 6);
        wrapper = new MockComposerWrapper();
        wrapper.setUnderlyingDecimals(address(underlyingOft), 6);

        shareAdapter = new MockOFTLikeAdapter(address(wrapper));

        configId = router.addAsset(address(underlyingOft), address(wrapper), address(shareAdapter), 18);
    }

    function _compose(bytes32 guid, uint256 amountLD, bytes memory inner) internal pure returns (bytes32, bytes memory) {
        bytes memory msg_ = abi.encodePacked(uint64(1), uint32(1), bytes32(uint256(amountLD)), bytes32(uint256(0)), inner);
        return (guid, msg_);
    }

    function test_initialize_onlyOnce() public {
        vm.expectRevert();
        router.initialize(ENDPOINT, address(this));
    }

    function test_addAsset_writesMappings() public view {
        bytes32 got1 = router.oAppToConfigId(address(underlyingOft));
        bytes32 got2 = router.oAppToConfigId(address(shareAdapter));
        assertEq(got1, configId);
        assertEq(got2, configId);

        (
            bool isSet,
            bool deprecated,
            address u,
            address w,
            address a,
            bool forwardPaused,
            bool reversePaused,
            uint8 sharedDecimals
        ) = router.assetConfigs(configId);

        assertTrue(isSet);
        assertFalse(deprecated);
        assertEq(u, address(underlyingOft));
        assertEq(w, address(wrapper));
        assertEq(a, address(shareAdapter));
        assertFalse(forwardPaused);
        assertFalse(reversePaused);
        assertEq(sharedDecimals, 18);
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

    function test_lzCompose_forward_paused_refunds() public {
        uint256 amountUnderlying = 500e6;
        underlyingOft.mint(address(router), amountUnderlying);

        router.setAssetPause(configId, true, false);

        DStockComposerRouter.RouteMsg memory r =
            DStockComposerRouter.RouteMsg({finalDstEid: 30367, finalTo: bytes32(uint256(uint160(address(0xCAFE)))), refundBsc: REFUND, minAmountLD2: 0});
        (, bytes memory message) = _compose(bytes32("guid2"), amountUnderlying, abi.encode(r));

        vm.prank(ENDPOINT);
        router.lzCompose(address(underlyingOft), bytes32("guid2"), message, address(0), "");

        // underlying refunded to REFUND, not wrapped
        assertEq(underlyingOft.balanceOf(REFUND), amountUnderlying);
        assertEq(underlyingOft.balanceOf(address(wrapper)), 0);
    }

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
}

