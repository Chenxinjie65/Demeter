# Demeter V2 Architecture Decision Log

[中文](zh/DECISIONS_ZH.md)

This log records the canonical architectural decisions for the V2 singleton index-fund protocol.
Rejected alternatives are retained only when they explain a current security or product boundary.

---

## DEC-001 - Index Fund, Not Managed AMM


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

## DEC-002 - Actual-Reserve Proportional Issue and Redemption


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

## DEC-003 - Epoch-Banded Dutch Auctions


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

## DEC-004 - Chainlink Anchor Plus External DEX TWAP Guard


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

## DEC-005 - Stable Pool Identity and Immutable Asset List


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

## DEC-006 - No General Lock/Callback Core in Phase 1


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

## DEC-007 - Immutable Core Instead of Proxies


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

## DEC-008 - Restricted AssetRegistry Instead of AddressProvider


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

## DEC-009 - Per-Pool ERC-20 Shares


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

## DEC-010 - Permissionless Pool Creation Within Global Bounds


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

## DEC-011 - Exact Snapshot Targets and Uniform Plan Scaling


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

## DEC-012 - Public Stale-Plan Invalidation and Guardian Cancellation


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

## DEC-013 - Manager Operation Guard Across Fixed Modules


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

## DEC-014 - Append-Only Cancellation and Launch AUM Control


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
