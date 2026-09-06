// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IAaveV3Pool
 * @notice Minimal subset of the Aave V3 Pool interface used by Demeter adapters.
 *
 * @dev
 * This is intentionally a slim interface to:
 * - Reduce compilation time.
 * - Make it clear which external calls are relied upon.
 *
 * For the full interface, refer to the official Aave V3 repository.
 */
/**
 * @title IAaveV3PoolAddressesProvider
 * @notice Minimal interface for the Aave V3 PoolAddressesProvider.
 *         Used by deployment scripts to resolve the live Pool address from the
 *         canonical, immutable PoolAddressesProvider address.
 */
interface IAaveV3PoolAddressesProvider {
    /// @notice Returns the address of the Aave V3 Pool contract.
    function getPool() external view returns (address);
}

interface IAaveV3Pool {
    /**
     * @notice Supplies an `amount` of underlying `asset` into the Aave pool.
     *
     * @param asset The address of the underlying asset to supply.
     * @param amount The amount to be supplied.
     * @param onBehalfOf The address that will receive the aTokens.
     * @param referralCode A referral code for potential rewards (usually 0).
     */
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /**
     * @notice Withdraws an `amount` of underlying `asset` from the Aave pool.
     *
     * @param asset The address of the underlying asset to withdraw.
     * @param amount The underlying amount to be withdrawn, or type(uint256).max for entire balance.
     * @param to The address that will receive the underlying tokens.
     * @return withdrawn The final amount withdrawn.
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256 withdrawn);
}


