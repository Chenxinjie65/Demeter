// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title V2Errors
 * @notice Namespaced custom errors for the Demeter V2 contracts.
 * @custom:security-contact security@demeter.protocol
 */
library V2Errors {
    error V2Errors__ZeroAddress(bytes32 field);
    error V2Errors__EmptyArray(bytes32 field);
    error V2Errors__ArrayLengthMismatch(uint256 expected, uint256 actual);
    error V2Errors__DuplicateAsset(address asset);
    error V2Errors__AssetNotEnabled(address asset);
    error V2Errors__InvalidWeights(uint256 sum);
    error V2Errors__ZeroWeight(uint256 index);
    error V2Errors__InvalidBps(bytes32 field, uint256 value);
    error V2Errors__InvalidTime(bytes32 field, uint256 value);
    error V2Errors__Unauthorized(address caller);
    error V2Errors__InvalidPoolKind(uint8 kind);
    error V2Errors__InvalidPoolId(bytes32 poolId);
    error V2Errors__InvalidState(uint8 state);
    error V2Errors__PolicyNotDelayed(uint256 effectiveAt, uint256 currentTime);
    error V2Errors__PolicyNotActive(uint256 effectiveAt, uint256 currentTime);
    error V2Errors__InvalidConfig(bytes32 field);
    error V2Errors__UnsupportedToken(address token);
    error V2Errors__PoolNotFound(bytes32 poolId);
    error V2Errors__PoolClosed(bytes32 poolId);
    error V2Errors__PoolNotBootstrapped(bytes32 poolId);
    error V2Errors__PoolAlreadyBootstrapped(bytes32 poolId);
    error V2Errors__BootstrapExpired(uint256 deadline, uint256 currentTime);
    error V2Errors__BootstrapNotReady(uint256 effectiveAt, uint256 currentTime);
    error V2Errors__InvalidBootstrapAmount(uint256 index, uint256 amount);
    error V2Errors__InvalidInitialSupply(uint256 supply);
    error V2Errors__InvalidMetadata(bytes32 field);
    error V2Errors__AssetsNotSorted(address previous, address current);
    error V2Errors__FullRedemptionBlocked(bytes32 poolId);
    error V2Errors__InvalidShareAmount(uint256 amount);
    error V2Errors__DeadlineExpired(uint256 deadline, uint256 currentTime);
    error V2Errors__UnauthorizedCreator(address caller, address creator);
    error V2Errors__PolicyFamilyDisabled(bytes32 familyId);
    error V2Errors__PolicyAlreadyActive(bytes32 poolId);
    error V2Errors__GlobalBoundExceeded(bytes32 field, uint256 value, uint256 maximum);
    error V2Errors__ConfigVersionChanged(uint64 expected, uint64 actual);
    error V2Errors__ActivePlan(bytes32 poolId);
    error V2Errors__InvalidQuoteAsset(address expected, address actual);
    error V2Errors__IndexPolicyNotSet();
    error V2Errors__AuctionAuthorityNotSet();
    error V2Errors__BootstrapHashMismatch(bytes32 expected, bytes32 actual);
    error V2Errors__InitialPolicyRequired(bytes32 poolId);
    error V2Errors__PolicyFamilyMismatch(bytes32 expected, bytes32 actual);
    error V2Errors__InitialPolicyHashMismatch(bytes32 expected, bytes32 actual);
    error V2Errors__SeedHashMismatch(bytes32 expected, bytes32 actual);
    error V2Errors__InvalidRecipient(address recipient);
    error V2Errors__InvalidBootstrapper(address bootstrapper);
    error V2Errors__UnauthorizedBootstrapper(address caller, address expected);
    error V2Errors__InsufficientAllowance(
        address token, address owner, address spender, uint256 required, uint256 actual
    );
    error V2Errors__InsufficientBalance(address token, address owner, uint256 required, uint256 actual);
    error V2Errors__ExactTransferMismatch(address token, uint256 expected, uint256 actual);
    error V2Errors__TokenNotInPool(address token);
    error V2Errors__InvalidAuctionAuthority(address authority);
    error V2Errors__PoolLocked(bytes32 poolId);
    error V2Errors__ZeroReserve(address asset);
    error V2Errors__ZeroOutput(bytes32 poolId);
    error V2Errors__InvalidPolicyFamily(bytes32 familyId);
    error V2Errors__PolicyVersionMismatch(uint64 expected, uint64 actual);
    error V2Errors__PlanInvalid(bytes32 poolId);
    error V2Errors__AuctionNotActive(bytes32 poolId, uint64 auctionNonce);
    error V2Errors__AuctionExpired(uint256 endTime, uint256 currentTime);
    error V2Errors__BidTooLarge(uint256 requested, uint256 available);
    error V2Errors__PriceTooLow(uint256 offered, uint256 required);
    error V2Errors__OracleUnsafe(bytes32 reason);
    error V2Errors__PendingPolicyExists(bytes32 poolId, uint64 version);
    error V2Errors__NoPendingPolicy(bytes32 poolId);
    error V2Errors__ImmutablePolicy(bytes32 poolId);
    error V2Errors__InvalidEpoch(uint256 previousEpoch, uint256 nextEpoch);
    error V2Errors__PolicyHashMismatch(bytes32 expected, bytes32 actual);
    error V2Errors__NoRebalanceNeeded(bytes32 poolId);
    error V2Errors__RebalanceNotEligible(bytes32 poolId, uint256 driftBps);
    error V2Errors__PlanAlreadyActive(bytes32 poolId);
    error V2Errors__PlanExpired(uint256 expiresAt, uint256 currentTime);
    error V2Errors__PlanStillValid(bytes32 poolId);
    error V2Errors__NoSurplus(address asset);
    error V2Errors__NoDeficit(address asset);
    error V2Errors__NoTurnoverCapacity(bytes32 poolId);
    error V2Errors__Paused();
    error V2Errors__MathOverflow(bytes32 field);
}
