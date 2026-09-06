// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";
import {AuctionMath} from "src/libraries/AuctionMath.sol";
import {PoolId} from "src/libraries/PoolId.sol";
import {ProportionalMath} from "src/libraries/ProportionalMath.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";

contract PoolIdHarness {
    function derive(
        uint256 chainId,
        address manager,
        address creator,
        address[] calldata assets,
        bytes32 familyId,
        bytes32 salt
    ) external pure returns (bytes32) {
        return PoolId.derive(chainId, manager, creator, assets, familyId, salt);
    }
}

contract ProportionalMathHarness {
    function amountIn(uint256 reserve, uint256 shares, uint256 supply) external pure returns (uint256) {
        return ProportionalMath.amountIn(reserve, shares, supply);
    }

    function amountOut(uint256 reserve, uint256 shares, uint256 supply) external pure returns (uint256) {
        return ProportionalMath.amountOut(reserve, shares, supply);
    }

    function valueWad(uint256 amount, uint256 price, uint8 decimals) external pure returns (uint256) {
        return ProportionalMath.valueWad(amount, price, decimals);
    }

    function valueWadUp(uint256 amount, uint256 price, uint8 decimals) external pure returns (uint256) {
        return ProportionalMath.valueWadUp(amount, price, decimals);
    }

    function targetRaw(uint256 value, uint16 weight, uint256 price, uint8 decimals) external pure returns (uint256) {
        return ProportionalMath.targetRawAmount(value, weight, price, decimals);
    }
}

contract AuctionMathHarness {
    function pairPrice(uint256 base, uint256 quote) external pure returns (uint256) {
        return AuctionMath.pairPriceWad(base, quote);
    }

    function startPrice(uint256 referencePrice, uint16 premium) external pure returns (uint256) {
        return AuctionMath.startPrice(referencePrice, premium);
    }

    function endPrice(uint256 referencePrice, uint16 discount) external pure returns (uint256) {
        return AuctionMath.endPrice(referencePrice, discount);
    }

    function currentPrice(uint256 start, uint256 end, uint64 startTime, uint64 endTime, uint256 timestamp)
        external
        pure
        returns (uint256)
    {
        return AuctionMath.currentPrice(start, end, startTime, endTime, timestamp);
    }

    function payment(uint256 sellAmount, uint256 price, uint8 sellDecimals, uint8 buyDecimals)
        external
        pure
        returns (uint256)
    {
        return AuctionMath.paymentRaw(sellAmount, price, sellDecimals, buyDecimals);
    }

    function maxSell(uint256 buyAmount, uint256 price, uint8 sellDecimals, uint8 buyDecimals)
        external
        pure
        returns (uint256)
    {
        return AuctionMath.maxSellRaw(buyAmount, price, sellDecimals, buyDecimals);
    }
}

contract V2MathTest is Test {
    PoolIdHarness private poolIdHarness;
    ProportionalMathHarness private proportional;
    AuctionMathHarness private auction;

    address private constant MANAGER = address(0x1000);
    address private constant CREATOR = address(0x2000);
    bytes32 private constant FAMILY = keccak256("STATIC_INDEX_V1");
    bytes32 private constant SALT = keccak256("creator-salt");

    function setUp() public {
        poolIdHarness = new PoolIdHarness();
        proportional = new ProportionalMathHarness();
        auction = new AuctionMathHarness();
    }

    function test_PoolId_IsDeterministicAndCreatorBound() public view {
        address[] memory assets = _assets();
        bytes32 first = poolIdHarness.derive(block.chainid, MANAGER, CREATOR, assets, FAMILY, SALT);
        bytes32 second = poolIdHarness.derive(block.chainid, MANAGER, CREATOR, assets, FAMILY, SALT);
        bytes32 attacker = poolIdHarness.derive(block.chainid, MANAGER, address(0xBAD), assets, FAMILY, SALT);

        assertEq(first, second);
        assertNotEq(first, attacker);
    }

    function test_PoolId_AssetOrderChangesIdentity() public view {
        address[] memory assets = _assets();
        bytes32 canonical = poolIdHarness.derive(block.chainid, MANAGER, CREATOR, assets, FAMILY, SALT);
        (assets[0], assets[1]) = (assets[1], assets[0]);
        bytes32 reordered = poolIdHarness.derive(block.chainid, MANAGER, CREATOR, assets, FAMILY, SALT);
        assertNotEq(canonical, reordered);
    }

    function testFuzz_ProportionalMath_RoundingProtectsFund(uint128 reserve, uint128 supply, uint128 shares)
        public
        view
    {
        if (reserve == 0 || supply == 0 || shares == 0) return;
        shares = uint128(bound(shares, 1, supply));

        uint256 required = proportional.amountIn(reserve, shares, supply);
        uint256 returned = proportional.amountOut(reserve, shares, supply);

        assertGe(required, returned);
        assertLe(required - returned, 1);
    }

    function test_ProportionalMath_UsesWholeTokenPriceAndNativeDecimals() public view {
        uint256 value = proportional.valueWad(2_000_000, 1e18, 6);
        assertEq(value, 2e18);

        uint256 target = proportional.targetRaw(10e18, 2_500, 2e18, 6);
        assertEq(target, 1_250_000);
    }

    function test_ProportionalMath_RejectsZeroSupply() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__InvalidInitialSupply.selector, 0));
        proportional.amountIn(1, 1, 0);
    }

    function testFuzz_RiskValueFragmentationCannotUndercount(
        uint128 first,
        uint128 second,
        uint128 rawPrice,
        uint8 rawDecimals
    ) public view {
        uint256 price = bound(uint256(rawPrice), 1, 1e30);
        uint8 decimals = uint8(bound(uint256(rawDecimals), 0, 36));
        uint256 fragmented =
            proportional.valueWadUp(first, price, decimals) + proportional.valueWadUp(second, price, decimals);
        uint256 aggregate = proportional.valueWadUp(uint256(first) + second, price, decimals);
        assertGe(fragmented, aggregate);
    }

    function test_AuctionMath_BoundsAndMonotonicity() public view {
        uint256 start = auction.startPrice(1e18, 100);
        uint256 end = auction.endPrice(1e18, 200);

        assertEq(start, 1.01e18);
        assertEq(end, 0.98e18);
        assertEq(auction.currentPrice(start, end, 100, 200, 100), start);
        assertEq(auction.currentPrice(start, end, 100, 200, 200), end);
        assertGt(auction.currentPrice(start, end, 100, 200, 150), end);
        assertLt(auction.currentPrice(start, end, 100, 200, 150), start);
    }

    function testFuzz_AuctionMath_CurrentPriceIsBounded(uint64 elapsed) public view {
        uint64 startTime = 100;
        uint64 endTime = 1_100;
        uint256 timestamp = bound(elapsed, 0, 2_000);
        uint256 price = auction.currentPrice(1.1e18, 0.9e18, startTime, endTime, timestamp);
        assertGe(price, 0.9e18);
        assertLe(price, 1.1e18);
    }

    function test_AuctionMath_PaymentAcrossDecimalsRoundsUp() public view {
        uint256 price = auction.pairPrice(2_000e18, 1e18);
        uint256 payment = auction.payment(1e18, price, 18, 6);
        assertEq(payment, 2_000e6);

        uint256 rounded = auction.payment(1, price, 18, 6);
        assertEq(rounded, 1);
    }

    function testFuzz_AuctionMath_MaxSellNeverExceedsBuyBudget(
        uint96 rawBudget,
        uint96 rawPrice,
        uint8 rawSellDecimals,
        uint8 rawBuyDecimals
    ) public view {
        uint256 budget = bound(uint256(rawBudget), 1, type(uint96).max);
        uint256 price = bound(uint256(rawPrice), 1, 1e30);
        uint8 sellDecimals = uint8(bound(uint256(rawSellDecimals), 0, 36));
        uint8 buyDecimals = uint8(bound(uint256(rawBuyDecimals), 0, 36));
        uint256 sell = auction.maxSell(budget, price, sellDecimals, buyDecimals);
        if (sell == 0 || sell == type(uint256).max) return;
        assertLe(auction.payment(sell, price, sellDecimals, buyDecimals), budget);
    }

    function _assets() private pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(0x3000);
        assets[1] = address(0x4000);
    }
}
