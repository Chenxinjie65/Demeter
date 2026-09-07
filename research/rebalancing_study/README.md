# Demeter V2 Rebalancing Research

This workspace contains two complementary comparison tools. Neither is
production execution evidence.

## V2 Policy Comparison

`v2_compare.py` is the canonical V2 research entry point. It uses a deterministic
four-asset market path so results are reproducible without network access. It
compares:

- buy and hold;
- immediate calendar direct swaps as a non-protocol benchmark;
- immediate drift-triggered direct swaps as a non-protocol benchmark;
- conservative, balanced, and responsive V2 bounded-auction policies.

Each V2 policy runs under:

- healthy liquidity;
- thin liquidity;
- oracle interruptions;
- configuration invalidation and replanning;
- zero fill until expiry.

The V2 model implements the research equivalents of:

- calendar and drift triggers;
- minimum plan intervals;
- uniform scaling under plan turnover and per-asset adjustment caps;
- auction opening delay and plan expiry;
- start-premium to maximum-discount price progression;
- daily partial-fill and external-liquidity limits;
- fail-closed oracle days;
- configuration invalidation;
- destination-drift completion;
- cumulative execution cost, gas, unfilled notional, and time-to-fill metrics.

Run the deterministic comparison and its tests from the repository root:

```bash
python3 -m unittest research.rebalancing_study.test_v2_model -v
python3 -m research.rebalancing_study.v2_compare
```

Generated outputs are ignored by Git:

```text
research/rebalancing_study/output/v2_strategy_comparison/comparison.csv
research/rebalancing_study/output/v2_strategy_comparison/report.md
```

## Historical Market Comparison

`simulate.py` compares buy-and-hold, rejected passive-AMM approaches, a simple
full-fill Dutch auction, and manager-directed swaps over cached daily market
data. It remains useful for understanding why the public-AMM alternatives were
rejected, but it is not the canonical V2 lifecycle model.

Install optional plotting dependencies and run it with:

```bash
python3 -m pip install -r research/rebalancing_study/requirements.txt
python3 -m research.rebalancing_study.simulate
```

It fetches public daily data from CoinGecko with a Yahoo Finance fallback and
writes CSV, Markdown, and PNG output below `research/rebalancing_study/output/`.

## Interpretation Rules

- Compare tracking error, turnover, cost, completion rate, expiry, invalidation,
  and unfilled notional together. Final return alone is not an acceptance test.
- Direct-swap benchmarks assume execution authority that the V2 Manager does not
  have. They are economic references, not implementation candidates.
- Zero-fill and oracle-outage scenarios should preserve value except for market
  movement; they must never force execution outside the auction bounds.
- A lower trigger usually improves tracking at the cost of more plans, turnover,
  gas, and exposure to failed execution.
- Results depend on explicit assumptions and must not be generalized beyond the
  tested price path, AUM, liquidity, and cost inputs.

## Known Limitations

The deterministic model uses daily prices and aggregate USD notional. It does
not yet model intraday Chainlink rounds, Uniswap observations, pairwise auction
ordering, bidder competition, MEV, token decimals, block-level gas, or real
venue depth. The curve cost is a conservative portfolio-level approximation,
not an exact Solidity execution trace.

Before production, calibrate the profiles with target-chain fork data, real
asset liquidity, bidder hedge quotes, oracle downtime observations, and AUM-
scaled lot sizes. The binding protocol design remains
`docs/REBALANCING_WHITEPAPER.md` and `docs/ARCHITECTURE_V2.md`.
