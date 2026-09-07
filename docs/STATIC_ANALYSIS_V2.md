# Demeter V2 Static Analysis Triage

[中文](zh/STATIC_ANALYSIS_V2_ZH.md)

> Tool: Slither 0.11.3
> Cross-check: Aderyn 0.6.8
>
>
> Scope: V2 core, oracle, interfaces, types, and libraries. Tests, scripts, and
> dependencies are filtered; the former V1 implementation is absent from the
> working tree and remains available only in Git history.

## Command

```bash
bash script/v2/check-slither.sh
```

The wrapper uses Slither's `--fail-high` gate and writes each run to a fresh
temporary JSON report. Slither reported no
Critical/High V2 issue. Medium and lower results remain visible and are triaged
below rather than suppressed.
The release size budgets are 22,000 bytes for `DemeterManager` and 23,500
bytes for `AuctionRebalance`; both remain below the EIP-170 limit with margin.
The following detector classes require explicit review rather than mechanical
suppression.

## Triaged Results

### Auction `bid` writes after Manager settlement

Slither reports reentrancy because `bid` updates fill counters after the
external Manager call. This order is required because Manager defensively reads
the pre-fill auction and current curve before moving either token. Manager asset
operations share one `ReentrancyGuardTransient`; its guarded state is exposed
read-only so plan start, policy activation, stale invalidation, and Guardian
cancellation fail during token callbacks. `bid` also rechecks auction/plan
state immediately after settlement. Exact balance deltas and focused callback
tests cover issue, redeem, and bid paths. Verdict: accepted design, not an
exploitable reentry under the supported-token model.

### Zero-initialized local variables

Slither lists accumulator integers, booleans, and the `bytes32 reason` local as
uninitialized. Solidity initializes all such memory/stack values to zero;
every non-reverting `reason` branch assigns a value before emission. Verdict:
false positive.

### Strict equality, timestamps, and calls in loops

Enum-state equality, zero-balance checks, deadlines, policy epochs, and auction
windows are exact protocol semantics. External calls in asset loops are bounded
by the global hard cap of 32 assets and the deployment default of 16; they read
fixed protocol dependencies or admitted standard tokens. Verdict: expected and
bounded; gas is still part of the per-chain release test.

### Helper-based zero-address checks

Registry constructor and guardian writes use `_validateAddress` or
`_validateContract`; Slither does not follow the helper for its syntactic
detector. Focused tests cover zero and no-code inputs. Verdict: false positive.

### Ignored second Uniswap `observe` return

The TWAP adapter requires only tick cumulatives. Seconds-per-liquidity data is
not used to price or admit liquidity onchain; historical liquidity review is an
offchain asset-admission requirement. Verdict: intentional unused output.

### Complexity and naming

Plan formation, pool creation, settlement, and Router redemption exceed
Slither's generic complexity threshold because each enforces a full risk
envelope. They remain separated by state ownership and have focused plus
stateful tests. Interface return names that shadow function names are ABI-only
cosmetic findings. Verdict: accepted for this release; avoid adding more logic
to `AuctionRebalance` without extracting pure calculation code.

### Aderyn high-severity cross-check

Aderyn reports `H-1 Reentrancy: State change after external call` for broad
classes of fixed dependency reads and token transfers. Registry, Policy,
Manager, Share, and oracle dependencies are fixed or timelock-controlled;
Solidity `view` interface calls execute through `STATICCALL`. Manager token
operations use one transient guard, fixed modules observe that guard, and
callback regression tests cover issue, redeem, policy activation, stale-plan
invalidation, and bid cancellation. The remaining Auction post-settlement write
rechecks the active plan and auction state. Verdict: detector overbreadth; the
known callback boundary is covered under the supported-token model.

Aderyn also reports `H-2 Unprotected initializer` for
`IndexPolicy.initialPolicyHash`. The function is an `external view` getter with
no state write and is not an initializer. Verdict: name-based false positive.

## Remaining Gate

This triage is not an independent security audit. Production remains blocked
until an external audit, production-asset fork tests, governance-role review,
and the other open items in `RELEASE_CHECKLIST_V2.md` are complete.
