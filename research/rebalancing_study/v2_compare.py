from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path
from typing import Sequence

from .v2_model import (
    AuctionPolicy,
    AuctionSimulator,
    ExecutionStress,
    SimulationResult,
    simulate_direct_rebalance,
)


DEFAULT_OUTPUT = Path(__file__).resolve().parent / "output" / "v2_strategy_comparison"
INITIAL_AUM_USD = 10_000_000.0
AUM_LEVELS_USD = (1_000_000.0, 5_000_000.0, 10_000_000.0, 25_000_000.0, 50_000_000.0)


def deterministic_price_path(days: int = 365) -> list[list[float]]:
    """Create a reproducible four-asset path with trend, cycles, and shocks."""
    if days < 2:
        raise ValueError("At least two days are required.")
    path: list[list[float]] = []
    starts = (2_000.0, 30_000.0, 30.0, 7.0)
    daily_trends = (0.00045, 0.00030, 0.00065, 0.00020)
    phases = (0.0, 1.2, 2.4, 3.1)
    amplitudes = (0.12, 0.08, 0.20, 0.15)
    for day in range(days):
        row: list[float] = []
        for index, start in enumerate(starts):
            cycle = 1.0 + amplitudes[index] * math.sin(day / (19.0 + index * 5.0) + phases[index])
            trend = math.exp(daily_trends[index] * day)
            shock = 1.0
            if 105 <= day < 135:
                shock *= (0.78, 0.88, 0.63, 0.70)[index]
            if 245 <= day < 270:
                shock *= (1.15, 1.08, 1.32, 1.20)[index]
            row.append(start * trend * cycle * shock)
        path.append(row)
    return path


def default_policy_schedule(days: int) -> dict[int, Sequence[float]]:
    schedule: dict[int, Sequence[float]] = {
        0: (0.35, 0.35, 0.20, 0.10),
        90: (0.30, 0.40, 0.20, 0.10),
        180: (0.40, 0.30, 0.18, 0.12),
        270: (0.34, 0.36, 0.20, 0.10),
    }
    return {day: weights for day, weights in schedule.items() if day < days}


def policy_matrix() -> tuple[AuctionPolicy, ...]:
    common = {
        "destination_bps": 75.0,
        "min_plan_interval_days": 7,
        "plan_duration_days": 7,
        "opening_delay_days": 1,
        "auction_duration_days": 6,
        "max_turnover_bps": 2_000.0,
        "max_asset_adjustment_bps": 1_000.0,
        "start_premium_bps": 25.0,
        "max_discount_bps": 150.0,
    }
    return (
        AuctionPolicy(name="V2 Conservative", trigger_bps=250.0, **common),
        AuctionPolicy(name="V2 Balanced", trigger_bps=175.0, **common),
        AuctionPolicy(name="V2 Responsive", trigger_bps=100.0, **common),
    )


def stress_matrix(days: int) -> tuple[ExecutionStress, ...]:
    return (
        ExecutionStress(
            name="Healthy liquidity",
            daily_fill_fraction=0.65,
            daily_liquidity_usd=1_500_000.0,
            hedge_cost_bps=8.0,
            gas_cost_usd=35.0,
        ),
        ExecutionStress(
            name="Thin liquidity",
            daily_fill_fraction=0.20,
            daily_liquidity_usd=250_000.0,
            hedge_cost_bps=25.0,
            gas_cost_usd=55.0,
        ),
        ExecutionStress(
            name="Oracle interruptions",
            daily_fill_fraction=0.45,
            daily_liquidity_usd=750_000.0,
            hedge_cost_bps=15.0,
            gas_cost_usd=45.0,
            oracle_outage_days=tuple(day for day in range(days) if day % 61 in {0, 1, 2}),
        ),
        ExecutionStress(
            name="Configuration churn",
            daily_fill_fraction=0.35,
            daily_liquidity_usd=500_000.0,
            hedge_cost_bps=18.0,
            gas_cost_usd=45.0,
            config_invalidation_days=tuple(day for day in range(days) if day % 17 == 0),
        ),
        ExecutionStress(
            name="Zero fill",
            daily_fill_fraction=0.0,
            daily_liquidity_usd=0.0,
            hedge_cost_bps=0.0,
            gas_cost_usd=0.0,
        ),
    )


def run_comparison(days: int = 365, initial_aum_usd: float = INITIAL_AUM_USD) -> list[SimulationResult]:
    path = deterministic_price_path(days)
    schedule = default_policy_schedule(days)
    results: list[SimulationResult] = [
        simulate_direct_rebalance(
            "Buy And Hold",
            path,
            schedule,
            initial_aum_usd,
            trigger_bps=None,
            cost_bps=0.0,
            rebalance_on_calendar=False,
        ),
        simulate_direct_rebalance(
            "Calendar Direct Swap", path, schedule, initial_aum_usd, trigger_bps=None, cost_bps=35.0
        ),
        simulate_direct_rebalance(
            "Calendar + Drift Direct Swap",
            path,
            schedule,
            initial_aum_usd,
            trigger_bps=175.0,
            cost_bps=35.0,
        ),
    ]
    for policy in policy_matrix():
        for stress in stress_matrix(days):
            results.append(AuctionSimulator(policy, stress).run(path, schedule, initial_aum_usd))
    return results


def run_aum_sweep(days: int = 365) -> list[SimulationResult]:
    path = deterministic_price_path(days)
    schedule = default_policy_schedule(days)
    balanced = next(policy for policy in policy_matrix() if policy.name == "V2 Balanced")
    stresses = stress_matrix(days)[:2]
    return [
        AuctionSimulator(balanced, stress).run(path, schedule, aum)
        for stress in stresses
        for aum in AUM_LEVELS_USD
    ]


def write_csv_report(path: Path, results: Sequence[SimulationResult]) -> None:
    rows = [result.to_row() for result in results]
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def write_markdown_report(path: Path, results: Sequence[SimulationResult]) -> None:
    rows = [result.to_row() for result in results]
    lines = [
        "# Demeter V2 Rebalancing Strategy Comparison",
        "",
        "> Deterministic research model. Results are not production execution evidence.",
        "",
        "## Metrics",
        "",
        (
            "| Strategy | Stress | Final value ($m) | Avg drift (bps) | "
            "Turnover ($m) | Cost ($k) | Cumulative unfilled ($m) | Completion % | Expired | Invalidated |"
        ),
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append(
            "| "
            f"{row['strategy']} | {row['stress']} | "
            f"{float(row['final_value_usd']) / 1_000_000.0:.3f} | "
            f"{float(row['average_drift_bps']):.1f} | "
            f"{float(row['turnover_usd']) / 1_000_000.0:.3f} | "
            f"{float(row['execution_cost_usd']) / 1_000.0:.2f} | "
            f"{float(row['unfilled_notional_usd']) / 1_000_000.0:.3f} | "
            f"{float(row['completion_rate_pct']):.1f} | "
            f"{int(row['plans_expired'])} | {int(row['plans_invalidated'])} |"
        )
    lines.extend(
        [
            "",
            "## Interpretation",
            "",
            "- Buy-and-hold isolates market beta and incurs no rebalance cost.",
            "- Direct-swap benchmarks assume immediate execution and do not represent an allowed Manager path.",
            "- V2 policies use the same bounded plan mechanics but different drift triggers.",
            "- Stress profiles expose the trade-off between tracking error, turnover, fill quality, and liveness.",
            (
                "- Zero-fill results measure safe failure: reserves remain invested "
                "while plans expire without forced execution."
            ),
            "- Configuration-churn results measure permissionless invalidation and later replanning.",
            "",
            (
                "Production decisions require calibrated intraday data, real venue depth, "
                "bidder behavior, oracle observations, gas, and chain-specific fork tests."
            ),
        ]
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_aum_report(path: Path, results: Sequence[SimulationResult]) -> None:
    rows = [result.to_row() for result in results]
    lines = [
        "# Demeter V2 AUM Scalability Comparison",
        "",
        (
            "> Fixed-liquidity sensitivity for the balanced V2 policy. "
            "This is not a recommended AUM cap."
        ),
        "",
        (
            "| Stress | Initial AUM ($m) | Avg drift (bps) | Completion % | "
            "Expired | Turnover/AUM | Cumulative unfilled/AUM |"
        ),
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        initial_aum = float(row["initial_aum_usd"])
        lines.append(
            "| "
            f"{row['stress']} | {initial_aum / 1_000_000.0:.1f} | "
            f"{float(row['average_drift_bps']):.1f} | "
            f"{float(row['completion_rate_pct']):.1f} | "
            f"{int(row['plans_expired'])} | "
            f"{float(row['turnover_usd']) / initial_aum:.3f} | "
            f"{float(row['unfilled_notional_usd']) / initial_aum:.3f} |"
        )
    lines.extend(
        [
            "",
            (
                "Fixed external liquidity becomes a tighter constraint as AUM grows. "
                "A production soft cap must be based on calibrated venue depth and "
                "observed fill quality, not this synthetic threshold."
            ),
        ]
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Compare bounded Demeter V2 auction policies.")
    parser.add_argument("--days", type=int, default=365)
    parser.add_argument("--initial-aum", type=float, default=INITIAL_AUM_USD)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    results = run_comparison(args.days, args.initial_aum)
    aum_results = run_aum_sweep(args.days)
    write_csv_report(args.output / "comparison.csv", results)
    write_markdown_report(args.output / "report.md", results)
    write_csv_report(args.output / "aum_scaling.csv", aum_results)
    write_aum_report(args.output / "aum_scaling.md", aum_results)
    print(
        f"Wrote {len(results)} strategy/stress results and "
        f"{len(aum_results)} AUM sensitivity results to {args.output}"
    )


if __name__ == "__main__":
    main()
