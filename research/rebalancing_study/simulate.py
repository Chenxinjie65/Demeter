from __future__ import annotations

import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path

from .config import OUTPUT_DIR, ScenarioConfig, StudyConfig, WindowConfig
from .data_loader import MarketPoint, load_or_fetch_prices
from .plots import (
    plot_cumulative_cost_breakdown,
    plot_cumulative_turnover,
    plot_cost_efficiency,
    plot_drift_to_target,
    plot_final_value_comparison,
    plot_nav_curves,
    plot_weight_trajectory,
)
from .strategies import (
    StrategyState,
    apply_dutch_auction_rebalance,
    apply_event_metrics,
    apply_manager_active_rebalance,
    apply_passive_damped_step,
    apply_passive_swap_rebalance,
    composition_distance,
    maybe_schedule_passive_damped_rebalance,
    release_cooldown_if_elapsed,
    target_units,
)


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        raise ValueError(f"No rows to write for {path.name}.")
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames: list[str] = []
    seen: set[str] = set()
    for row in rows:
        for key in row.keys():
            if key not in seen:
                seen.add(key)
                fieldnames.append(key)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def current_policy_target_weights(
    schedule: dict,
    day,
) -> list[float]:
    target = schedule[min(schedule.keys())]
    for target_day in sorted(schedule):
        if target_day > day:
            break
        target = schedule[target_day]
    return list(target)


def initialize_states(
    scenario: ScenarioConfig,
    first_point: MarketPoint,
    initial_aum_usd: float,
    initial_weights: list[float],
) -> dict[str, StrategyState]:
    prices = [first_point.prices[asset] for asset in scenario.assets]
    units = target_units(initial_aum_usd, initial_weights, prices)
    return {
        "Buy And Hold": StrategyState("Buy And Hold", scenario.assets, units[:], initial_weights[:]),
        "Passive Swap": StrategyState("Passive Swap", scenario.assets, units[:], initial_weights[:]),
        "Passive Damped": StrategyState("Passive Damped", scenario.assets, units[:], initial_weights[:]),
        "Dutch Auction": StrategyState("Dutch Auction", scenario.assets, units[:], initial_weights[:]),
        "Manager Active": StrategyState("Manager Active", scenario.assets, units[:], initial_weights[:]),
    }


def process_event(state: StrategyState, event_rows: list[dict[str, object]], event) -> None:
    if event is None:
        return
    apply_event_metrics(state, event)
    event_rows.append(event.to_row())


def calculate_max_drawdown(nav_series: list[float]) -> float:
    peak = nav_series[0]
    max_drawdown = 0.0
    for nav in nav_series:
        peak = max(peak, nav)
        drawdown = 0.0 if peak <= 0 else (peak - nav) / peak
        max_drawdown = max(max_drawdown, drawdown)
    return max_drawdown * 100.0


def compute_summary(
    daily_rows: list[dict[str, object]],
    event_rows: list[dict[str, object]],
    initial_aum_usd: float,
) -> list[dict[str, object]]:
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in daily_rows:
        grouped[str(row["strategy"])].append(row)
    event_grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in event_rows:
        event_grouped[str(row["strategy"])].append(row)

    summary_rows: list[dict[str, object]] = []
    for strategy, rows in grouped.items():
        rows.sort(key=lambda item: str(item["date"]))
        nav_series = [float(row["nav_index"]) for row in rows]
        value_series = [float(row["total_value_usd"]) for row in rows]
        daily_returns = [
            (value_series[idx] / value_series[idx - 1]) - 1.0
            for idx in range(1, len(value_series))
            if value_series[idx - 1] > 0.0
        ]
        realized_volatility = (
            statistics.pstdev(daily_returns) * math.sqrt(365.0) * 100.0
            if len(daily_returns) > 1
            else 0.0
        )

        final_row = rows[-1]
        strategy_events = event_grouped.get(strategy, [])
        schedule_events = [row for row in strategy_events if str(row.get("event_type", "")) == "schedule"]
        turnover_usd = float(final_row["cumulative_turnover_usd"])
        net_cost_usd = float(final_row["cumulative_net_cost_usd"])
        cost_per_turnover_bps = 0.0 if turnover_usd == 0.0 else (net_cost_usd / turnover_usd) * 10_000.0

        summary_rows.append(
            {
                "strategy": strategy,
                "final_value_usd": float(final_row["total_value_usd"]),
                "return_pct": ((float(final_row["total_value_usd"]) / initial_aum_usd) - 1.0) * 100.0,
                "cumulative_net_cost_usd": net_cost_usd,
                "cumulative_explicit_cost_usd": float(final_row["cumulative_explicit_cost_usd"]),
                "cumulative_implicit_cost_usd": float(final_row["cumulative_implicit_cost_usd"]),
                "cumulative_fee_income_usd": float(final_row["cumulative_fee_income_usd"]),
                "cumulative_turnover_usd": turnover_usd,
                "turnover_multiple_of_aum": turnover_usd / initial_aum_usd,
                "rebalance_count": int(final_row["rebalance_count"]),
                "avg_drift_to_target_bps": statistics.fmean(float(row["drift_to_target_bps"]) for row in rows),
                "max_drift_to_target_bps": max(float(row["drift_to_target_bps"]) for row in rows),
                "avg_active_target_gap_bps": statistics.fmean(float(row["active_target_gap_bps"]) for row in rows),
                "max_active_target_gap_bps": max(float(row["active_target_gap_bps"]) for row in rows),
                "avg_drift_to_active_bps": statistics.fmean(float(row["drift_to_active_bps"]) for row in rows),
                "max_drift_to_active_bps": max(float(row["drift_to_active_bps"]) for row in rows),
                "days_not_idle": sum(1 for row in rows if str(row["lifecycle"]) != "Idle"),
                "realized_volatility_pct": realized_volatility,
                "max_drawdown_pct": calculate_max_drawdown(nav_series),
                "net_cost_per_turnover_bps": cost_per_turnover_bps,
                "schedule_count": len(schedule_events),
                "calendar_trigger_count": sum(1 for row in schedule_events if "calendar" in str(row.get("trigger_type", ""))),
                "drift_trigger_count": sum(1 for row in schedule_events if "drift" in str(row.get("trigger_type", ""))),
                "step_cap_hit_count": sum(
                    1 for row in schedule_events if str(row.get("step_cap_applied", "")).lower() == "true"
                ),
                "turnover_cap_hit_count": sum(
                    1 for row in schedule_events if str(row.get("turnover_cap_applied", "")).lower() == "true"
                ),
            }
        )
    summary_rows.sort(key=lambda item: float(item["final_value_usd"]), reverse=True)
    return summary_rows


def write_run_report(
    path: Path,
    summary_rows: list[dict[str, object]],
    scenario: ScenarioConfig,
    window: WindowConfig,
    cache_paths: dict[str, Path],
) -> None:
    best_final = max(summary_rows, key=lambda row: float(row["final_value_usd"]))
    lowest_turnover = min(summary_rows, key=lambda row: float(row["cumulative_turnover_usd"]))
    buy_and_hold = next(row for row in summary_rows if str(row["strategy"]) == "Buy And Hold")
    passive_damped = next(row for row in summary_rows if str(row["strategy"]) == "Passive Damped")

    lines = [
        "# Rebalancing Study Run",
        "",
        f"- Scenario: `{scenario.name}`",
        f"- Assets: `{', '.join(scenario.assets)}`",
        f"- Window: `{window.start_date.isoformat()}` to `{window.end_date.isoformat()}`",
        f"- Price caches: `{', '.join(f'{asset}:{cache_paths[asset].name}' for asset in scenario.assets)}`",
        "",
        "## Headline Findings",
        "",
        f"- Buy-and-hold benchmark ends at `${float(buy_and_hold['final_value_usd']):,.0f}`.",
        f"- Best final value is `{best_final['strategy']}` at `${float(best_final['final_value_usd']):,.0f}`.",
        (
            f"- `Passive Damped` schedules {int(passive_damped['schedule_count'])} migrations, "
            f"with {int(passive_damped['drift_trigger_count'])} drift-triggered schedules."
        ),
        (
            f"- Lowest turnover is `{lowest_turnover['strategy']}` at "
            f"${float(lowest_turnover['cumulative_turnover_usd']):,.0f}."
        ),
        "",
        "## Summary Table",
        "",
        "| Strategy | Final Value ($m) | Return % | Excess vs Hold ($k) | Turnover ($m) | Avg Drift (bps) | Max DD % |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    buy_and_hold_value = float(buy_and_hold["final_value_usd"])
    for row in summary_rows:
        excess_value = float(row["final_value_usd"]) - buy_and_hold_value
        lines.append(
            "| "
            f"{row['strategy']} | "
            f"{float(row['final_value_usd']) / 1_000_000.0:.2f} | "
            f"{float(row['return_pct']):.2f} | "
            f"{excess_value / 1_000.0:.1f} | "
            f"{float(row['cumulative_turnover_usd']) / 1_000_000.0:.2f} | "
            f"{float(row['avg_drift_to_target_bps']):.1f} | "
            f"{float(row['max_drawdown_pct']):.2f} |"
        )

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def run_single_study(
    config: StudyConfig,
    scenario: ScenarioConfig,
    window: WindowConfig,
) -> tuple[dict[str, Path], list[dict[str, object]], list[dict[str, object]], list[dict[str, object]], Path]:
    schedule = scenario.target_schedule(window.start_date.year, window.end_date.year)
    cache_paths, prices = load_or_fetch_prices(scenario.assets, window.start_date, window.end_date)
    if not prices:
        raise RuntimeError(f"Price series is empty for {scenario.slug} {window.name}.")

    first_target = current_policy_target_weights(schedule, prices[0].day)
    states = initialize_states(scenario, prices[0], config.initial_aum_usd, first_target)
    daily_rows: list[dict[str, object]] = []
    event_rows: list[dict[str, object]] = []

    for day_index, point in enumerate(prices):
        policy_weights = current_policy_target_weights(schedule, point.day)
        scheduled_weights = schedule.get(point.day)
        calendar_due = scheduled_weights is not None
        price_vector = [point.prices[asset] for asset in scenario.assets]

        damped_state = states["Passive Damped"]
        release_cooldown_if_elapsed(damped_state, day_index)
        schedule_event = maybe_schedule_passive_damped_rebalance(
            damped_state,
            day=point.day,
            day_index=day_index,
            policy_weights=policy_weights,
            prices=price_vector,
            rebalance_window_days=config.damped_rebalance_window_days,
            cooldown_days=config.damped_cooldown_days,
            min_rebalance_interval_days=config.damped_min_rebalance_interval_days,
            drift_trigger_bps=config.damped_drift_trigger_bps,
            hysteresis_bps=config.damped_hysteresis_bps,
            max_step_weight_delta_bps=config.damped_max_step_weight_delta_bps,
            max_turnover_bps=config.damped_max_turnover_bps,
            calendar_due=calendar_due,
        )
        process_event(damped_state, event_rows, schedule_event)

        if calendar_due:
            for strategy_name, state in states.items():
                if strategy_name in {"Buy And Hold", "Passive Damped"}:
                    continue
                if composition_distance(state.active_weights, policy_weights) <= 1e-12:
                    continue
                if strategy_name == "Passive Swap":
                    event = apply_passive_swap_rebalance(
                        state,
                        point.day,
                        policy_weights,
                        price_vector,
                        config.passive_swap_fee_bps,
                    )
                elif strategy_name == "Dutch Auction":
                    event = apply_dutch_auction_rebalance(
                        state,
                        point.day,
                        policy_weights,
                        price_vector,
                        config.auction_clearing_discount_bps,
                        config.auction_operational_cost_bps,
                    )
                else:
                    event = apply_manager_active_rebalance(
                        state,
                        point.day,
                        policy_weights,
                        price_vector,
                        config.active_base_fee_bps,
                        config.active_slippage_bps_multiplier,
                        config.active_impact_bps_quadratic,
                    )
                process_event(state, event_rows, event)

        damped_event = apply_passive_damped_step(
            damped_state,
            day=point.day,
            day_index=day_index,
            policy_weights=policy_weights,
            prices=price_vector,
            beta_max=config.damped_beta_max,
            mu=config.damped_mu,
            kappa=config.damped_kappa,
            fee_min_bps=config.damped_fee_min_bps,
            fee_mid_bps=config.damped_fee_mid_bps,
            fee_max_bps=config.damped_fee_max_bps,
            epsilon_bps=config.damped_epsilon_bps,
        )
        process_event(damped_state, event_rows, damped_event)

        for strategy_name, state in states.items():
            total_value = state.total_value(price_vector)
            actual = state.actual_weights(price_vector)
            drift_to_target = composition_distance(actual, policy_weights) * 10_000.0
            drift_to_active = composition_distance(actual, state.active_weights) * 10_000.0
            active_target_gap = composition_distance(state.active_weights, policy_weights) * 10_000.0
            row: dict[str, object] = {
                "date": point.day.isoformat(),
                "strategy": strategy_name,
                "total_value_usd": total_value,
                "nav_index": total_value / config.initial_aum_usd,
                "drift_to_target_bps": drift_to_target,
                "drift_to_active_bps": drift_to_active,
                "active_target_gap_bps": active_target_gap,
                "cumulative_turnover_usd": state.cumulative_turnover_usd,
                "cumulative_explicit_cost_usd": state.cumulative_explicit_cost_usd,
                "cumulative_implicit_cost_usd": state.cumulative_implicit_cost_usd,
                "cumulative_fee_income_usd": state.cumulative_fee_income_usd,
                "cumulative_net_cost_usd": state.cumulative_net_cost_usd,
                "rebalance_count": state.rebalance_count,
                "lifecycle": state.lifecycle,
            }
            for asset, price, unit, actual_weight, active_weight, policy_weight in zip(
                scenario.assets,
                price_vector,
                state.units,
                actual,
                state.active_weights,
                policy_weights,
                strict=True,
            ):
                slug = asset.lower()
                row[f"price_{slug}_usd"] = price
                row[f"units_{slug}"] = unit
                row[f"actual_weight_{slug}"] = actual_weight
                row[f"active_weight_{slug}"] = active_weight
                row[f"policy_weight_{slug}"] = policy_weight
            daily_rows.append(row)

    summary_rows = compute_summary(daily_rows, event_rows, config.initial_aum_usd)
    run_dir = OUTPUT_DIR / scenario.slug / window.name
    run_dir.mkdir(parents=True, exist_ok=True)

    write_csv(run_dir / "daily_results.csv", daily_rows)
    write_csv(run_dir / "rebalance_events.csv", event_rows)
    write_csv(run_dir / "summary_metrics.csv", summary_rows)
    write_run_report(run_dir / "analysis_report.md", summary_rows, scenario, window, cache_paths)

    title_prefix = f"{scenario.name} | {window.name}"
    plot_nav_curves(daily_rows, run_dir / "nav_curves.png", title_prefix)
    plot_final_value_comparison(summary_rows, run_dir / "final_value_comparison.png", title_prefix)
    plot_cost_efficiency(summary_rows, run_dir / "cost_efficiency.png", title_prefix)
    plot_cumulative_cost_breakdown(daily_rows, run_dir / "cumulative_cost_breakdown.png", title_prefix)
    plot_cumulative_turnover(daily_rows, run_dir / "cumulative_turnover.png", title_prefix)
    plot_drift_to_target(daily_rows, run_dir / "drift_to_target.png", title_prefix)
    plot_weight_trajectory(daily_rows, scenario.assets, run_dir / "weight_trajectory.png", title_prefix)

    return cache_paths, daily_rows, event_rows, summary_rows, run_dir


def write_batch_report(path: Path, rows: list[dict[str, object]]) -> None:
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        grouped[str(row["scenario"])].append(row)

    lines = [
        "# Batch Rebalancing Study",
        "",
        "This report summarizes all configured scenario and time-window runs.",
        "",
    ]

    for scenario, scenario_rows in grouped.items():
        lines.append(f"## {scenario}")
        lines.append("")
        lines.append("| Window | Strategy | Final Value ($m) | Excess vs Hold ($k) | Turnover ($m) | Avg Drift (bps) |")
        lines.append("| --- | --- | ---: | ---: | ---: | ---: |")
        for row in sorted(scenario_rows, key=lambda item: (str(item["window"]), -float(item["final_value_usd"]))):
            lines.append(
                "| "
                f"{row['window']} | "
                f"{row['strategy']} | "
                f"{float(row['final_value_usd']) / 1_000_000.0:.2f} | "
                f"{float(row['excess_vs_hold_usd']) / 1_000.0:.1f} | "
                f"{float(row['cumulative_turnover_usd']) / 1_000_000.0:.2f} | "
                f"{float(row['avg_drift_to_target_bps']):.1f} |"
            )
        lines.append("")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def simulate() -> Path:
    config = StudyConfig()
    batch_rows: list[dict[str, object]] = []

    for scenario in config.scenarios:
        for window in config.windows:
            _, _, _, summary_rows, run_dir = run_single_study(config, scenario, window)
            buy_and_hold = next(row for row in summary_rows if str(row["strategy"]) == "Buy And Hold")
            hold_value = float(buy_and_hold["final_value_usd"])
            for row in summary_rows:
                batch_rows.append(
                    {
                        "scenario": scenario.name,
                        "scenario_slug": scenario.slug,
                        "assets": ",".join(scenario.assets),
                        "window": window.name,
                        "start_date": window.start_date.isoformat(),
                        "end_date": window.end_date.isoformat(),
                        "strategy": row["strategy"],
                        "final_value_usd": row["final_value_usd"],
                        "return_pct": row["return_pct"],
                        "excess_vs_hold_usd": float(row["final_value_usd"]) - hold_value,
                        "cumulative_net_cost_usd": row["cumulative_net_cost_usd"],
                        "cumulative_turnover_usd": row["cumulative_turnover_usd"],
                        "avg_drift_to_target_bps": row["avg_drift_to_target_bps"],
                        "max_drawdown_pct": row["max_drawdown_pct"],
                        "schedule_count": row["schedule_count"],
                        "output_dir": str(run_dir),
                    }
                )

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    write_csv(OUTPUT_DIR / "batch_summary.csv", batch_rows)
    write_batch_report(OUTPUT_DIR / "batch_report.md", batch_rows)
    return OUTPUT_DIR


def main() -> None:
    output_dir = simulate()
    print(f"Outputs: {output_dir}")


if __name__ == "__main__":
    main()
