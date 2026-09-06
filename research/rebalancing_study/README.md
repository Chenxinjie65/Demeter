# Rebalancing Study

> This is historical research and a comparison harness. `Passive Swap` and
> `Passive Damped` model rejected AMM-based alternatives; they are not the
> canonical Demeter V2 execution path. The current design is specified in
> `docs/REBALANCING_WHITEPAPER.md` and uses bounded public auctions.

This workspace compares a buy-and-hold benchmark plus four rebalancing methods for multiple index-vault scenarios:

- buy and hold
- passive swap rebalancing
- passive damped rebalancing
- Dutch auction rebalancing
- manager active rebalancing

The current study matrix covers:

- yearly windows: `2022`, `2023`, `2024`, `2025`
- continuous windows: `2022-2023`, `2024-2025`, `2022-2025`
- a two-asset index: `ETH/BTC`
- a four-asset index: `ETH/BTC/SOL/LINK`

The simulator tracks:

- final vault value
- excess return versus buy-and-hold
- cumulative turnover
- explicit cost, implicit cost, and fee income
- daily drift to policy target
- drawdown and realized volatility
- damped-module trigger and cap usage

## Run

From the repo root:

```bash
python3 -m research.rebalancing_study.simulate
```

The script will:

1. fetch and cache daily prices per asset in `research/rebalancing_study/data/`
2. run every configured `scenario x window`
3. write per-run CSVs and PNG charts under `research/rebalancing_study/output/<scenario>/<window>/`
4. write batch-level summary files to `research/rebalancing_study/output/`

## Output Layout

Per run:

- `daily_results.csv`
- `rebalance_events.csv`
- `summary_metrics.csv`
- `analysis_report.md`
- `nav_curves.png`
- `final_value_comparison.png`
- `cost_efficiency.png`
- `cumulative_cost_breakdown.png`
- `cumulative_turnover.png`
- `drift_to_target.png`
- `weight_trajectory.png`

Batch level:

- `batch_summary.csv`
- `batch_report.md`

## Notes

- The model is a research comparison, not a production execution simulator.
- The passive swap strategy uses a weighted-pool equilibrium approximation generalized to `n` assets.
- The passive damped strategy approximates the previously proposed
  `wTarget -> wPath -> wEffective` design with calendar triggers, drift
  triggers, hysteresis, step caps, turnover caps, and dynamic fee bands. That
  design was rejected for the V2 fund because it exposes holders to AMM
  repricing loss.
- The auction and active strategies use explicit execution-cost models on shared target transitions.
- Multi-year results are especially useful for checking whether a rebalance method only works in one market regime or remains robust across trend and mean-reversion periods.
