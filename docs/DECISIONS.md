# Demeter — Architecture Decision Log

[中文](zh/DECISIONS_ZH.md)

> This file records architectural decisions made during development, with emphasis
> on cases where an initial approach was **rejected** in favour of a better one.
> Understanding *why* a design was changed is as important as knowing what was chosen.
>
> Status note: DEC-001 through DEC-012 record the legacy Factory/Beacon/Vault
> prototype. They are historical reference, not canonical V2 design. DEC-013
> and later define the auction-based index-fund architecture approved on
> 2026-08-31.

---

## DEC-001 — Anti-ERC-4626: In-Kind Basket Model

**Decision date:** Phase 1 (Architecture Design)
**Status:** Superseded for V2; retained as legacy reference

### Considered
Implementing the vault as an ERC-4626 tokenised vault with a single base asset (e.g. USDC).

### Rejected because
ERC-4626 requires converting all deposits into a single denominator. For a multi-asset index vault this introduces:
1. **Oracle-latency arbitrage** — any price movement between oracle update and deposit/withdrawal can be exploited.
2. **Forced swap slippage** — converting basket assets to/from a base asset imposes a cost on every user.
3. **Misaligned incentives** — users join/exit with the full basket, not a single currency.

### Chosen
Strict in-kind proportional basket model:
- `depositMulti()` — caller supplies all basket assets in exact stored-reserve
  ratios.
- `withdrawMulti()` — caller receives all basket assets proportionally to their share.
- No forced conversion; no base-asset denominator.
- `DemeterRouter` provides single-asset UX on top without modifying vault semantics.

---

## DEC-002 — Flash Accounting via EIP-1153 (Transient Storage)

**Decision date:** Phase 1 (Architecture Design)
**Status:** Superseded for V2; retained as legacy reference

### Considered
Using regular `SSTORE`/`SLOAD` for mid-transaction balance tracking, or a reentrancy mutex stored in regular storage.

### Rejected because
- `SSTORE` costs ~20,000 gas on a cold slot write.
- Per-asset delta tracking requires multiple storage writes per deposit/withdrawal.
- Regular storage must be explicitly reset, creating cleanup risk if execution reverts mid-flow.

### Chosen
EIP-1153 transient storage (`TSTORE`/`TLOAD`) — ~100 gas per operation, automatically cleared at transaction end:
- `TransientLock.sol` — transient reentrancy guard.
- `FlashAccounting.sol` — per-asset deltas tracked as transient state; all deltas must net to zero before the lock closes.
- Voucher-confirm pattern: `flashSub` before transfer, `flashAdd` after — atomically verified.
- **Requires** `evm_version = "cancun"` in `foundry.toml`.

---

## DEC-003 — Virtual Offset vs Dead Shares for Inflation Defence

**Decision date:** Phase 2 (VaultMath implementation)
**Status:** Superseded for V2; retained as legacy reference

### Considered
**Option A: Dead shares** — mint a small number of shares to `address(0)` on first deposit (OpenZeppelin ERC-4626 v4 approach).

**Option B: Virtual offset** — add phantom amounts to the share/AUM totals in all calculations without minting anything.

### Rejected (Option A) because
Dead shares require a special first-deposit code path, complicate the share accounting, and leave a non-zero `totalSupply` that must be accounted for in fee calculations.

### Chosen (Option B)
Virtual offset with `VIRTUAL_SHARES = 1e10` and `VIRTUAL_AUM = 1`:
```
sharesToMint = amount × (totalShares + VIRTUAL_SHARES) / (totalAUM + VIRTUAL_AUM)
```
- Eliminates first-deposit inflation attacks.
- Anchors initial share price at ~1 USD/share.
- No special case needed; formula is uniform across all deposits.
- Zero tokens minted to `address(0)`.

---

## DEC-004 — Beacon Proxy vs UUPS vs Transparent Proxy

**Decision date:** Phase 1 (Architecture Design)
**Status:** Superseded for V2; retained as legacy reference

### Considered
- **UUPS** — upgrade logic in the implementation.
- **Transparent Proxy** — upgrade logic in the proxy; admin vs user slots.
- **Beacon Proxy** — all proxies share one `UpgradeableBeacon`; upgrading the beacon upgrades all vaults atomically.

### Chosen
Beacon Proxy (`UpgradeableBeacon` + `BeaconProxy`):
- Factory can create unlimited vaults; all share the same implementation.
- A single `upgradeTo()` call on the beacon upgrades every vault simultaneously.
- `VaultStorage` uses ERC-7201 namespaced storage slot to prevent collisions.
- `__gap[37]` reserved for future fields.

---

## DEC-005 — Buffer Ratio: 10% Idle / 90% Deployed

**Decision date:** Phase 1 (Architecture Design)
**Status:** Superseded for V2; retained as legacy reference

### Rationale
Aave V3 at 100% utilisation cannot service withdrawals — the pool `revert`s. A liquidity buffer in the vault itself ensures small withdrawals are always serviceable without touching Aave. 10% was chosen as a conservative default that minimises yield drag while providing meaningful liquidity.

`DEFAULT_BUFFER_RATIO_BPS = 1000` (10%)

**Post-deploy**: large vaults should evaluate their own optimal buffer based on expected withdrawal frequency and Aave utilisation trends.

---

## DEC-006 — Rounding Convention: Both Directions Round DOWN

**Decision date:** Phase 2 (VaultMath)
**Status:** Superseded for V2; retained as legacy reference

### Rationale
Both `depositMulti` (shares minted) and `withdrawMulti` (assets returned) round DOWN:
- **Shares minted** round DOWN → users receive slightly fewer shares → vault benefits.
- **Assets returned** round DOWN → users receive slightly fewer tokens → vault retains dust.

This is the "vault-favourable" convention used by ERC-4626 and Morpho. It prevents rounding-based value extraction attacks where a user repeatedly deposits/withdraws to drain rounding remainders.

---

## DEC-007 — One AaveV3Adapter Per Vault (Critical Design Fix)

**Decision date:** Phase 5 (AaveV3Adapter implementation)
**Status:** Superseded for V2; retained as legacy reference

### Original (incorrect) design
One shared `AaveV3Adapter` instance used by all vaults. `deposit()` called `pool.supply(..., onBehalfOf = msg.sender)` — the vault received the aTokens. `getBalance()` returned `aToken.balanceOf(owner)` where `owner` = the vault address.

### Why it was rejected
Aave V3's `pool.withdraw(asset, amount, to)` **burns aTokens from `msg.sender`** (the caller). If the adapter calls `pool.withdraw`, Aave burns from `address(adapter)`. But in the original design the adapter held zero aTokens (they were minted to the vault). Every real-Aave withdrawal would revert with insufficient aToken balance.

This was not caught during the architecture phase because the mock pool did not enforce aToken ownership — it simply transferred from the caller's balance.

### Chosen
One adapter instance per vault. The adapter itself holds the aTokens:
```solidity
// deposit:
pool.supply(asset, amount, address(this), 0);  // adapter holds aTokens

// getBalance (owner param accepted but unused):
balance = IERC20(aToken).balanceOf(address(this));
```
- `pool.withdraw` burns from `address(adapter)` — succeeds because adapter holds the aTokens.
- All aToken accounting for one vault is fully isolated in that vault's adapter.
- `getBalance(asset, owner)` ignores `owner` for interface compatibility with other adapter styles.

---

## DEC-008 — CircuitBreaker Bootstrap: `finalizeVault()` vs `setVault()`

**Decision date:** Phase 6 (CircuitBreaker / DemeterFactory)
**Status:** Superseded for V2; retained as legacy reference

### Problem
Classic chicken-and-egg: `DemeterFactory.createFund` must:
1. Deploy `CircuitBreaker` (vault address unknown yet).
2. Deploy `BeaconProxy` vault.
3. Tell the CB the real vault address.

Step 3 originally called `cb.setVault(vault)`. But `setVault` is `onlyOwner`. The CB's owner is the DAO multisig (passed at construction). The factory ≠ DAO multisig, so every call reverted with `OwnableUnauthorizedAccount`.

### Original approach (rejected)
`cb.setVault(vault)` — `onlyOwner`. Factory would need to be the owner, but the owner must be the DAO multisig from day one for security.

### Chosen
Added `finalizeVault(address vault_)` to `CircuitBreaker`:
- Gated by `address public immutable deployer` (set to `msg.sender` in constructor = the factory).
- One-time: `bool public vaultFinalized` prevents replay.
- The DAO multisig is the Ownable owner from the very first block; factory retains zero ongoing power.

```solidity
function finalizeVault(address vault_) external {
    if (msg.sender != deployer) revert Errors.NotManager();
    if (vaultFinalized)         revert Errors.AlreadyInitialized();
    if (vault_ == address(0))   revert Errors.ZeroAddress(bytes32("vault"));
    vaultFinalized = true;
    vault = vault_;
    emit VaultUpdated(old, vault_);
}
```

The `Errors.AlreadyInitialized()` error was added to `Errors.sol` specifically to support this pattern.

---

## DEC-009 — CircuitBreaker wired at `initialize()` vs post-deploy `setCircuitBreaker()`

**Decision date:** Phase 4 (DemeterFactory)
**Status:** Superseded for V2; retained as legacy reference

### Problem
The factory is not the vault manager, so it cannot call `vault.setCircuitBreaker(cb)` post-deploy — that function is `onlyManager`.

### Chosen
Added `circuitBreaker` field to `IDemeterVault.InitializeParams`. The factory encodes the CB address in `initData` and passes it to the `BeaconProxy` constructor, wiring the CB at initialization time before any external call can touch the vault.

---

## DEC-010 — `_collectFees` Position: Before Deposit (and Post-Deposit HWM Update)

**Decision date:** Phase 3 (DemeterVault, discovered during testing)
**Status:** Superseded for V2; retained as legacy reference

### Problem
`_collectFees` runs at the START of `depositMulti` before any tokens arrive. On the first-ever deposit: AUM = 0, totalShares = 0, NAV = 0. The HWM and `lastAUMSnapshot` are set to 0. On the second deposit: any positive NAV > 0 = HWM, triggering a spurious performance fee and a spurious management fee on a zero base.

### Fix
After tokens land and adapters are funded, update both values:
```solidity
// At the end of depositMulti, after _deployExcessToAdapters:
uint256 postAUM = VaultMath.computeTotalAUMUsd(s);
s.lastAUMSnapshot = postAUM;
uint256 postNAV   = VaultMath.navPerShare(postAUM, s.totalShares);
if (postNAV > s.highWaterMark) s.highWaterMark = postNAV;
```

---

## DEC-011 — Deployment Script: Deployer Serves All Roles Initially

**Decision date:** Phase 7 (Deployment Scripts)
**Status:** Superseded for V2; retained as legacy reference

### Rationale
For a testnet deployment where a single account controls everything, requiring separate multisig addresses for guardian, riskAdmin, and treasury would make the process unworkable. All role env vars default to the deployer address if unset. Post-deployment, each role should be rotated to the appropriate address via `ProtocolAddressProvider` governance calls.

This deployment assumption belongs to the legacy prototype and does not apply
to V2. V2 deployment roles are defined in `ROADMAP_V2.md` Phase 6.

---

## DEC-012 — CircuitBreaker Default Limit: `type(uint256).max / 2`

**Decision date:** Phase 4 (DemeterFactory)
**Status:** Superseded for V2; retained as legacy reference

### Rationale
A limit of 0 would block all withdrawals immediately. `type(uint256).max` risks overflow in cumulative arithmetic. `type(uint256).max / 2` is a sentinel "effectively unlimited" value that keeps the vault operational out-of-the-box while being clearly non-production. Operators must call `cb.setLimit(period, limitUsd)` before going live with a meaningful TVL.

---

## DEC-013 - Index Fund, Not Managed AMM

**Decision date:** 2026-08-31

**Status:** Canonical V2

### Considered

Use a Balancer-style weighted invariant and change pool weights over time so
arbitrageurs rebalance fund assets through a public `swap` function.

### Rejected because

Changing AMM weights changes the fund's quoted asset prices. Fund holders then
provide the inventory and economic concession for the arbitrage that restores
the new target. This is appropriate for a liquidity pool, but conflicts with
the product promise of tracked index exposure and bounded execution cost.

### Chosen

Demeter is an index fund. It holds a basket, issues transferable pro-rata
claims, and rebalances only through bounded auctions. Public DEX liquidity is
available to bidders and solvers outside the manager custody boundary, not as a
generic manager `swap` surface.

---

## DEC-014 - Actual-Reserve Proportional Issue and Redemption

**Decision date:** 2026-08-31

**Status:** Canonical V2

### Considered

Price issuance and redemption from oracle NAV, or require deposits in target
weight ratios.

### Rejected because

Oracle-priced issuance introduces stale-price and valuation risk. Target-weight
deposits differ from the actual basket after prices move and can transfer value
between entering and existing holders.

### Chosen

All direct issue and redemption operations use the manager's actual recorded
reserves in exact share proportion. Target weights and oracle prices are used
only to decide and bound rebalances. A router may offer single-asset UX entirely
outside the manager.

---

## DEC-015 - Epoch-Banded Dutch Auctions

**Decision date:** 2026-08-31

**Status:** Canonical V2

### Considered

Use direct DEX trades, TWAP-sliced manager trades, a gradual-weight AMM, a
public Dutch auction, or a solver-only batch auction.

### Rejected alternatives

- Direct and TWAP-sliced manager trades require an external-call, approval, and
  routing trust surface in the custody manager.
- Gradual AMM weights impose hidden adverse-selection cost on fund holders.
- A solver-only design creates an external availability dependency before the
  basic fund mechanism is proven.

### Chosen

Policy epochs and drift bands create a fixed plan with caps on turnover, lot
size, duration, and maximum discount. Public direct ERC-20 bidders fill one
surplus-to-deficit Dutch auction at a time. Partial fills are valid; expiry
leaves the basket redeemable and retains tracking error. Solvers may later
participate only through audited bounded-fill adapters.

---

## DEC-016 - Chainlink Anchor Plus External DEX TWAP Guard

**Decision date:** 2026-08-31

**Status:** Canonical V2

### Considered

Use Chainlink alone, DEX spot/TWAP alone, or an unconstrained median price for
auction pricing.

### Rejected because

Chainlink alone can lag fast markets. DEX spot prices are manipulable and TWAPs
can lag or become unrepresentative when liquidity changes. A moving oracle-fed
auction curve obscures the fund's worst execution price.

### Chosen

Chainlink provides the primary USD anchor; an approved external DEX TWAP
cross-checks the implied pair quote. The auction freezes a reference quote only
after both are valid and within a configured divergence bound. Any subsequent
disagreement, stale source, or price move outside the frozen safety band blocks
bids. A configuration-invalid plan can be invalidated publicly; a transient
oracle failure can be cancelled by the Guardian. Oracle values never set direct
issue or redemption amounts.

---

## DEC-017 - Stable Pool Identity and Immutable Asset List

**Decision date:** 2026-08-31

**Status:** Canonical V2

### Considered

Include target weights in `poolId` and mutate the pool's asset list as index
methodology changes.

### Rejected because

Weights are intentionally versioned and published by the pool creator within
governance-defined global bounds. Including them in a pool identifier makes
identity inconsistent after a valid policy update. In-place constituent
replacement expands reserve, oracle, and migration risk in the first fund
implementation.

### Chosen

`poolId` derives only from immutable fields. Policy versions contain weights.
Assets are immutable in Phase 1; a constituent replacement is a governed
migration to a new pool.

---

## DEC-018 - No General Lock/Callback Core in Phase 1

**Decision date:** 2026-08-31

**Status:** Canonical V2

### Considered

Make EIP-1153 lock/callback and flash accounting the mandatory path for every
fund operation.

### Rejected because

Proportional issue, redemption, and direct auction bids each have simple atomic
transfer semantics. Introducing arbitrary callbacks before a solver integration
widens the reentrancy and settlement surface without improving fund accounting.

### Chosen

Phase 1 uses explicit checks-effects-interactions and direct token transfers.
It still uses OpenZeppelin's transient reentrancy guard as a mutex across
Manager asset operations; that guard neither exposes a callback nor tracks
settlement deltas. General lock/callback and flash-accounting utilities remain
reusable references for a future audited solver adapter, but cannot change the
core fund invariants.

---

## DEC-019 - Immutable Core Instead of Proxies

**Decision date:** 2026-09-01

**Status:** Canonical V2

### Considered

Use UUPS, Transparent, or Beacon proxies to upgrade the shared manager and
other V2 contracts after deployment.

### Rejected because

The manager holds all fund assets. Upgrade authorization, implementation bugs,
and storage-layout migration become protocol-wide custody risks. The convenience
of a future logic replacement is not sufficient justification for making the
fund core upgradeable.

### Chosen

`DemeterManager`, `DemeterShare`, `AuctionRebalance`, `IndexPolicy`, and
`AssetRegistry` are non-upgradeable. Bugs are handled through narrowly scoped
pauses, a new deployment, and a governed migration. Critical addresses are
constructor immutables or Manager links written once before the first pool;
only explicit asset and risk configuration is mutable.

---

## DEC-020 - Restricted AssetRegistry Instead of AddressProvider

**Decision date:** 2026-09-01

**Status:** Canonical V2

### Considered

Adopt an Aave-style generic `AddressProvider` that dynamically returns current
module, router, oracle, and implementation addresses.

### Rejected because

A generic registry makes a governance address update capable of changing the
asset execution or custody boundary at runtime. That is inappropriate for a
fund manager that should not have arbitrary external execution capability.

### Chosen

`AssetRegistry` records only supported assets, immutable decimals, Chainlink
feeds, external DEX TWAP sources, risk limits, timelock, and guardian. Manager,
policy, auction, and share dependencies are immutable or one-time frozen.
Asset configuration updates increment versions, invalidating any plan created
under earlier configuration until a new reference snapshot is validated.

---

## DEC-021 - Per-Pool ERC-20 Shares

**Decision date:** 2026-09-01

**Status:** Canonical V2

### Considered

Use ERC-6909 claims inside the singleton manager in place of a per-pool ERC-20
share contract.

### Rejected because

ERC-6909 can efficiently represent many fungible IDs, but its `balanceOf`,
transfer, and approval ABI is not ERC-20 compatible. Fund shares need immediate
wallet, DEX, lending, and aggregator compatibility. A multi-token claim would
move this integration burden to every user-facing integration.

### Chosen

Each pool has a minimal, non-upgradeable ERC-20 `DemeterShare`. The manager
remains the sole minter and burner. ERC-6909 may be researched for a future
internal optimization, but cannot replace the externally held ERC-20 claim
without a separate migration design.

---

## DEC-022 - Permissionless Pool Creation Within Global Bounds

**Decision date:** 2026-09-01

**Status:** Canonical V2

Any address may create an index fund from the assets enabled by `AssetRegistry`;
the DAO does not approve pools individually. The creator submits the immutable
asset order, share metadata, bootstrapper, and policy family, then initializes
the pool within protocol-wide limits on asset count, weights, turnover, auction
parameters, and oracle safety.

Permissionless does not mean arbitrary-token or arbitrary-parameter deployment:
disabled assets remain rejected and only the governance timelock can change the
global risk bounds. The creator may publish delayed policy versions for its own
pool, but cannot change the asset list, move reserves, or bypass `effectiveAt`.

The creator address is included in `poolId` to bind ownership against copied
mempool calldata. Bootstrap is fixed to the creator-selected bootstrapper and
must observe every nonzero seed amount exactly before the deadline. Phase 1
rejects full redemption during an active plan; a full redemption outside a plan
closes the pool permanently so an active zero-supply pool cannot exist.

Policy hash means the canonical hash of all policy fields and the canonical
asset order; it is a creator commitment, not a per-pool timelock approval.
`ManagedIndex` and `ImmutableIndex` are fixed at creation. Only managed pools
accept later creator policies.

For a pool with more than two assets, each asset is quoted against one common
external quote asset. An `X/Y` quote is the ratio of the two validated common-
quote observations; Phase 1 does not support arbitrary direct pair mappings or
unreviewed multi-hop paths.

When an asset or relevant global configuration is disabled or versioned, any
plan using the old version is invalid and can be cancelled. Existing pools may
continue to redeem recorded reserves; new issue, plan, auction, and bid paths
are blocked until valid configuration exists.

---

## DEC-023 - Exact Snapshot Targets and Uniform Plan Scaling

**Decision date:** 2026-09-02

**Status:** Canonical V2

### Considered

Store target units per share at `1e18` precision and cap each asset's target
delta independently. Maintain a separate rolling-window turnover accumulator.

### Rejected because

Low-decimal assets combined with a large share supply can round a `1e18`-scaled
target to zero. Independent per-asset clipping can also make total target value
larger or smaller than the reference portfolio, creating deficits that no
bounded surplus can fund. A rolling accumulator adds timestamp buckets and
state without improving the explicit first-release rate bound.

### Chosen

Each plan stores target raw amounts and the snapshot share supply. A live target
is `mulDiv(targetRaw, liveSupply, snapshotSupply)`. All desired asset deltas use
one common scale chosen to satisfy both the per-asset adjustment cap and the
plan turnover cap; actual rounded sell/buy notional then defines the executable
budget. Risk consumption rounds up so fill fragmentation cannot undercount it.

Phase 1 bounds cross-plan turnover through `maxTurnoverBps` plus
`minPlanInterval`; it does not store a separate rolling-window accumulator.

---

## DEC-024 - Public Stale-Plan Invalidation and Guardian Cancellation

**Decision date:** 2026-09-02

**Status:** Canonical V2

### Considered

Allow any address to cancel a plan whenever an external oracle call reverts.

### Rejected because

A caller can deliberately constrain gas or exploit a temporary dependency
failure to make a valid safety probe fail, then grief the fund by repeatedly
cancelling otherwise valid auctions. A transient price failure already fails
closed without moving reserves.

### Chosen

Anyone may call `invalidatePlan` only when pinned asset, oracle, policy-family,
or policy-bound versions no longer match, or the plan has expired. Open and bid
recheck both price sources and simply revert during transient unsafe pricing.
The guardian may call `cancelPlan` for either Planned or AuctionActive state,
without changing targets or moving assets. Redemption remains available in all
cases.

Expiry uses explicit public cleanup rather than implicit overwrite: an ended
auction remains locked until `expireAuction`, and an expired plan remains
locked until `invalidatePlan`. Partial redemption remains available while
locked. This preserves a single authoritative lifecycle state and prevents an
old auction nonce from being rebound to a newly written plan.

---

## DEC-025 - Manager Operation Guard Across Fixed Modules

**Decision date:** 2026-09-04

**Status:** Canonical V2

### Considered

Rely only on each contract's local `nonReentrant` modifier and on governance
excluding callback-capable tokens.

### Rejected because

A token transfer occurs inside the Manager while Auction state may still be
updated after settlement. A callback cannot reenter the Manager, but a separate
contract-local guard does not stop it from calling permissionless Policy or
Auction lifecycle functions. That can start a plan during issue, activate a
new policy during a fill, or cancel/invalidate a plan between settlement checks
and the Auction's post-fill write.

### Chosen

Every Manager asset operation uses the same OpenZeppelin transient reentrancy
guard. The Manager exposes only its guard state: `isPoolActive` is false and
`isOperationActive` is true while entered. Fixed Policy and Auction modules
reject policy activation, plan creation, stale invalidation, and Guardian
cancellation during that interval; `bid` also rechecks active plan/auction
state after Manager settlement. This is a narrow coordination signal, not a
generic callback API, and it grants no caller permission to move assets.

Callback and balance-changing tokens remain excluded by the production asset
gate. Focused adversarial-token tests nevertheless prove that callback attempts
cannot mutate lifecycle state or mint shares between checks and settlement.

## DEC-026 - Append-Only Cancellation and Launch AUM Control

**Decision date:** 2026-09-05

**Status:** Canonical V2

An unpublished policy may be cancelled by its creator (or permissionlessly when
its pinned configuration is stale), but cancellation never deletes a published
version. In particular, cancelling initial version 1 leaves its hash and version
record intact; the pool cannot publish a replacement version 1 and remains
unbootstrappable until its bootstrap deadline expires. This preserves event
history and the append-only version invariant.

The first-release AUM cap is an operational launch control, not an onchain
oracle-priced hard limit. `issue` remains reserve-proportional and permissionless
within the approved asset set; introducing an onchain USD cap would add a new
pricing dependency to the claim path. Production operations therefore start
with a documented small-AUM pool, monitoring, and a governed rule for raising
that soft cap after fill-quality and liquidity evidence. A hard cap requires a
separate design decision and tests before it can be advertised as a protocol
invariant.
