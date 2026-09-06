// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Errors
 * @notice Library containing all custom errors used across the Demeter protocol.
 */
library Errors {
    // -------------------------------------------------------------------------
    // Price Oracle Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when addresses provider is zero address.
    error AddressesProviderIsZero();

    /// @dev Thrown when caller is not the RiskAdmin.
    error CallerNotRiskAdmin();

    /// @dev Thrown when arrays length mismatch.
    error ArraysLengthMismatch();

    /// @dev Thrown when feed is not set for an asset.
    error FeedNotSet();

    /// @dev Thrown when Chainlink answer is invalid (non-positive).
    error InvalidAnswer();

    /// @dev Thrown when Chainlink round is stale.
    error StaleRound();

    /// @dev Thrown when price is stale beyond maxStaleTime.
    error PriceStale();

    /// @dev Thrown when sequencer is down.
    error SequencerDown();

    /// @dev Thrown when grace period is not over after sequencer recovery.
    error GracePeriodNotOver();

    // -------------------------------------------------------------------------
    // Protocol Address Provider Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when trying to initialize or transfer ownership to the zero address.
    error InvalidOwner(address owner);

    /// @dev Thrown when attempting to set a registry entry to the zero address.
    /// @param key Identifier of the address being set (e.g. KEY_ORACLE, ROLE_GUARDIAN).
    error ZeroAddress(bytes32 key);

    // -------------------------------------------------------------------------
    // Asset Whitelist Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when attempting to add or check an asset that is the zero address.
    error AssetIsZero();

    /// @dev Thrown when attempting to add an asset that is already whitelisted.
    error AssetAlreadyWhitelisted();

    /// @dev Thrown when attempting to remove an asset that is not whitelisted.
    error AssetNotWhitelisted();

    // -------------------------------------------------------------------------
    // Vault — Initialization & Configuration
    // -------------------------------------------------------------------------

    /// @dev Thrown when a function that requires initialization is called on an uninitialized vault.
    error NotInitialized();

    /// @dev Thrown when the weight arrays do not match the asset array length.
    error WeightsMismatch();

    /// @dev Thrown when the sum of weights does not equal BPS (10_000).
    error WeightsNotNormalized();

    /// @dev Thrown when a weight of zero is provided for an asset.
    error InvalidWeight();

    /// @dev Thrown when an invalid fee bps value is provided.
    error InvalidFee();

    /// @dev Thrown when attempting to mutate an immutable vault.
    error VaultImmutable();

    // -------------------------------------------------------------------------
    // Vault — Access Control
    // -------------------------------------------------------------------------

    /// @dev Thrown when caller is not the vault manager.
    error NotManager();

    /// @dev Thrown when caller is not the guardian or manager.
    error NotGuardian();

    // -------------------------------------------------------------------------
    // Vault — Runtime Guards
    // -------------------------------------------------------------------------

    /// @dev Thrown when a deposit or rebalance is attempted while the vault is paused.
    error VaultPaused();

    /// @dev Thrown when an asset is not part of the vault's portfolio.
    error AssetNotInPortfolio(address asset);

    /// @dev Thrown when the output amount is below the caller-specified minimum.
    /// @param expected Minimum acceptable amount.
    /// @param actual   Amount that would actually be received.
    error SlippageExceeded(uint256 expected, uint256 actual);

    /// @dev Thrown when a share amount exceeds the owner's balance.
    /// @param requested Amount requested.
    /// @param available Amount available.
    error InsufficientShares(uint256 requested, uint256 available);

    /// @dev Thrown when zero shares would be minted or burned.
    error ZeroShares();

    /// @dev Thrown when a zero-amount token operation is attempted.
    error ZeroAmount();

    // -------------------------------------------------------------------------
    // Vault — Yield Adapter / Liquidity
    // -------------------------------------------------------------------------

    /**
     * @dev Thrown when the vault cannot service a withdrawal because:
     *      - The idle buffer is insufficient, AND
     *      - The underlying yield protocol (e.g. Aave at 100% utilization) cannot
     *        fulfil the requested withdrawal.
     *
     * @param asset     Asset that could not be fully withdrawn.
     * @param requested Amount that was needed from the yield protocol.
     */
    error AaveWithdrawalFailed(address asset, uint256 requested);

    /**
     * @dev Thrown when the total deliverable balance (idle + adapter) is less than
     *      the amount needed to honour a withdrawal.
     *
     * @param asset     Asset with insufficient liquidity.
     * @param requested Amount requested by the withdrawer.
     * @param available Amount actually available.
     */
    error InsufficientLiquidity(address asset, uint256 requested, uint256 available);

    // -------------------------------------------------------------------------
    // Vault — Rebalancing
    // -------------------------------------------------------------------------

    /**
     * @dev Thrown when `rebalance()` is called before the cooldown has elapsed.
     * @param remaining Seconds remaining until the next rebalance is permitted.
     */
    error CooldownNotElapsed(uint256 remaining);

    /// @dev Thrown when no asset exceeds the drift threshold and the weights are unchanged.
    error DeviationBelowThreshold();

    /**
     * @dev Thrown when a Uniswap V3 swap fails (e.g. insufficient liquidity or deadline).
     * @param tokenIn  Input token.
     * @param tokenOut Output token.
     */
    error SwapFailed(address tokenIn, address tokenOut);

    /// @dev Thrown when the swap router address has not been configured on the vault.
    error SwapRouterNotSet();

    // -------------------------------------------------------------------------
    // General
    // -------------------------------------------------------------------------

    /// @dev Thrown when a one-time initialisation function is called a second time.
    error AlreadyInitialized();

    // -------------------------------------------------------------------------
    // Router
    // -------------------------------------------------------------------------

    /// @dev Thrown when a native ETH transfer via `call{value}` fails (e.g. receiver reverts).
    error ETHTransferFailed();

    // -------------------------------------------------------------------------
    // Vault — Circuit Breaker
    // -------------------------------------------------------------------------

    /**
     * @dev Thrown when the circuit breaker blocks a withdrawal because the
     *      per-period outflow limit has been reached.
     *
     * @param requested  USD value of the withdrawal attempt.
     * @param allowed    Maximum USD value allowed in the current period.
     */
    error CircuitBreakerTripped(uint256 requested, uint256 allowed);
}
