// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IAssetAdapter
 * @notice Common interface for yield strategy adapters used by DemeterVault.
 *
 * @dev
 * Adapters act as lightweight, immutable connectors between the vault and
 * external protocols (Aave, Compound, etc).
 *
 * Design goals:
 * - Gas efficiency: no proxy layer; adapters are deployed as plain contracts.
 * - Simplicity: each adapter is responsible for a single protocol.
 * - Pluggability: the vault can change strategies by updating adapter addresses.
 */
interface IAssetAdapter {
    /**
     * @notice Deposits an asset into the underlying protocol on behalf of the caller.
     * @dev
     * - Caller (typically the vault) MUST have approved the adapter to spend `amount`.
     * - Implementations may assume the caller is trusted protocol code (not arbitrary EOAs).
     *
     * @param asset Underlying ERC-20 asset to deposit.
     * @param amount Amount of `asset` to deposit.
     * @return sharesOrTokens Amount of protocol-specific receipt tokens or accounting units obtained.
     */
    function deposit(address asset, uint256 amount) external returns (uint256 sharesOrTokens);

    /**
     * @notice Withdraws an asset from the underlying protocol back to the caller.
     * @dev
     * - Implementations may burn protocol-specific receipt tokens or perform equivalent accounting.
     *
     * @param asset Underlying ERC-20 asset to withdraw.
     * @param amount Amount of `asset` to withdraw (denominated in underlying units).
     * @param recipient Address that will receive the withdrawn tokens.
     * @return withdrawn Amount of underlying tokens actually withdrawn.
     */
    function withdraw(address asset, uint256 amount, address recipient) external returns (uint256 withdrawn);

    /**
     * @notice Returns the current underlying balance managed by this adapter for a given owner.
     * @dev
     * - For Aave-style protocols this typically corresponds to the aToken balance.
     * - `owner` is typically the vault address.
     *
     * @param asset Underlying ERC-20 asset.
     * @param owner Account whose balance should be reported (usually the vault).
     * @return balance Amount of underlying tokens controlled by the adapter for `owner`.
     */
    function getBalance(address asset, address owner) external view returns (uint256 balance);

    /**
     * @notice Claims any reward tokens accrued by the underlying protocol.
     * @dev
     * - Exact behavior is protocol-dependent.
     * - Implementations may revert if rewards are not supported.
     *
     * @param recipient Address that should receive the claimed rewards.
     * @return rewardToken Address of the reward token (if any).
     * @return amount Amount of rewards claimed.
     */
    function claimRewards(address recipient) external returns (address rewardToken, uint256 amount);
}


