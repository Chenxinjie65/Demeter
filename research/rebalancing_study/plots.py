from __future__ import annotations

import os
from collections import defaultdict
from pathlib import Path

os.environ.setdefault(
    "MPLCONFIGDIR",
    str(Path(__file__).resolve().parent / ".matplotlib"),
)

import matplotlib.dates as mdates
import matplotlib.pyplot as plt


PALETTE = {
    "Buy And Hold": "#1f77b4",
    "Passive Swap": "#d62728",
    "Passive Damped": "#2ca02c",
    "Dutch Auction": "#ff7f0e",
    "Manager Active": "#9467bd",
    "Target Schedule": "#111111",
}

LINESTYLES = {
    "Buy And Hold": "-",
    "Passive Swap": "--",
    "Passive Damped": "-.",
    "Dutch Auction": ":",
    "Manager Active": (0, (5, 1, 1, 1)),
    "Target Schedule": (0, (3, 2)),
}

MARKERS = {
    "Buy And Hold": "o",
    "Passive Swap": "s",
    "Passive Damped": "^",
    "Dutch Auction": "D",
    "Manager Active": "P",
}


def _prepare_axes(figsize: tuple[int, int] = (11, 6)):
    fig, ax = plt.subplots(figsize=figsize)
    ax.grid(True, alpha=0.25)
    return fig, ax


def _group_daily_rows(daily_rows: list[dict[str, object]]) -> dict[str, list[dict[str, object]]]:
    grouped: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in daily_rows:
        grouped[str(row["strategy"])].append(row)
    for rows in grouped.values():
        rows.sort(key=lambda item: str(item["date"]))
    return grouped


def plot_nav_curves(daily_rows: list[dict[str, object]], output_path: Path, title_prefix: str) -> None:
    grouped = _group_daily_rows(daily_rows)
    fig, ax = _prepare_axes()
    for strategy, rows in grouped.items():
        x = [mdates.datestr2num(str(item["date"])) for item in rows]
        y = [float(item["nav_index"]) for item in rows]
        ax.plot(
            x,
            y,
            linestyle=LINESTYLES.get(strategy, "-"),
            marker=MARKERS.get(strategy),
            markevery=max(len(x) // 10, 1),
            markersize=4.0,
            linewidth=2.3,
            label=strategy,
            color=PALETTE.get(strategy),
            alpha=0.95,
        )
    ax.set_title(f"{title_prefix} | Daily NAV Curves")
    ax.set_ylabel("NAV Index (Start = 1.0)")
    ax.set_xlabel("Date")
    ax.legend()
    ax.xaxis.set_major_locator(mdates.MonthLocator(interval=3))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)


def plot_final_value_comparison(summary_rows: list[dict[str, object]], output_path: Path, title_prefix: str) -> None:
    strategies = [str(row["strategy"]) for row in summary_rows]
    values = [float(row["final_value_usd"]) / 1_000_000.0 for row in summary_rows]
    colors = [PALETTE.get(strategy, "#4C4C4C") for strategy in strategies]
    fig, ax = _prepare_axes()
    bars = ax.bar(strategies, values, color=colors)
    ax.set_title(f"{title_prefix} | Final Vault Value")
    ax.set_ylabel("Final Value (USD millions)")
    ax.set_xlabel("Strategy")
    ax.bar_label(bars, fmt="%.2f")
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)


def plot_cost_efficiency(summary_rows: list[dict[str, object]], output_path: Path, title_prefix: str) -> None:
    strategies = [str(row["strategy"]) for row in summary_rows]
    values = [float(row["net_cost_per_turnover_bps"]) for row in summary_rows]
    colors = [PALETTE.get(strategy, "#4C4C4C") for strategy in strategies]
    fig, ax = _prepare_axes()
    bars = ax.bar(strategies, values, color=colors)
    ax.axhline(0.0, color="#222222", linewidth=1.0, alpha=0.7)
    ax.set_title(f"{title_prefix} | Net Cost Per Turnover")
    ax.set_ylabel("Net Cost (bps of turnover)")
    ax.set_xlabel("Strategy")
    ax.bar_label(bars, fmt="%.1f")
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)


def plot_cumulative_cost_breakdown(daily_rows: list[dict[str, object]], output_path: Path, title_prefix: str) -> None:
    grouped = _group_daily_rows(daily_rows)
    fig, ax = _prepare_axes()
    for strategy, rows in grouped.items():
        x = [mdates.datestr2num(str(item["date"])) for item in rows]
        y = [float(item["cumulative_net_cost_usd"]) / 1_000_000.0 for item in rows]
        ax.plot(
            x,
            y,
            linestyle=LINESTYLES.get(strategy, "-"),
            marker=MARKERS.get(strategy),
            markevery=max(len(x) // 10, 1),
            markersize=4.0,
            linewidth=2.3,
            label=strategy,
            color=PALETTE.get(strategy),
            alpha=0.95,
        )
    ax.set_title(f"{title_prefix} | Cumulative Net Cost")
    ax.set_ylabel("Cumulative Cost (USD millions)")
    ax.set_xlabel("Date")
    ax.legend()
    ax.xaxis.set_major_locator(mdates.MonthLocator(interval=3))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)


def plot_cumulative_turnover(daily_rows: list[dict[str, object]], output_path: Path, title_prefix: str) -> None:
    grouped = _group_daily_rows(daily_rows)
    fig, ax = _prepare_axes()
    for strategy, rows in grouped.items():
        x = [mdates.datestr2num(str(item["date"])) for item in rows]
        y = [float(item["cumulative_turnover_usd"]) / 1_000_000.0 for item in rows]
        ax.plot(
            x,
            y,
            linestyle=LINESTYLES.get(strategy, "-"),
            marker=MARKERS.get(strategy),
            markevery=max(len(x) // 10, 1),
            markersize=4.0,
            linewidth=2.3,
            label=strategy,
            color=PALETTE.get(strategy),
            alpha=0.95,
        )
    ax.set_title(f"{title_prefix} | Cumulative Turnover")
    ax.set_ylabel("Turnover (USD millions)")
    ax.set_xlabel("Date")
    ax.legend()
    ax.xaxis.set_major_locator(mdates.MonthLocator(interval=3))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)


def plot_drift_to_target(daily_rows: list[dict[str, object]], output_path: Path, title_prefix: str) -> None:
    grouped = _group_daily_rows(daily_rows)
    fig, ax = _prepare_axes()
    for strategy, rows in grouped.items():
        x = [mdates.datestr2num(str(item["date"])) for item in rows]
        y = [float(item["drift_to_target_bps"]) for item in rows]
        ax.plot(
            x,
            y,
            linestyle=LINESTYLES.get(strategy, "-"),
            marker=MARKERS.get(strategy),
            markevery=max(len(x) // 10, 1),
            markersize=4.0,
            linewidth=2.3,
            label=strategy,
            color=PALETTE.get(strategy),
            alpha=0.95,
        )
    ax.set_title(f"{title_prefix} | Daily Drift To Target")
    ax.set_ylabel("Absolute Weight Drift (bps)")
    ax.set_xlabel("Date")
    ax.legend()
    ax.xaxis.set_major_locator(mdates.MonthLocator(interval=3))
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)


def plot_weight_trajectory(
    daily_rows: list[dict[str, object]],
    assets: tuple[str, ...],
    output_path: Path,
    title_prefix: str,
) -> None:
    grouped = _group_daily_rows(daily_rows)
    target_rows = next(iter(grouped.values()))
    fig, axes = plt.subplots(len(assets), 1, figsize=(12, 3.6 * len(assets)), sharex=True)
    if len(assets) == 1:
        axes = [axes]

    for idx, asset in enumerate(assets):
        ax = axes[idx]
        asset_slug = asset.lower()
        for strategy, rows in grouped.items():
            x = [mdates.datestr2num(str(item["date"])) for item in rows]
            y = [float(item[f"actual_weight_{asset_slug}"]) * 100.0 for item in rows]
            ax.plot(
                x,
                y,
                linestyle=LINESTYLES.get(strategy, "-"),
                marker=MARKERS.get(strategy),
                markevery=max(len(x) // 10, 1),
                markersize=3.8,
                linewidth=2.1,
                label=strategy,
                color=PALETTE.get(strategy),
                alpha=0.95,
            )

        target_x = [mdates.datestr2num(str(item["date"])) for item in target_rows]
        target_y = [float(item[f"policy_weight_{asset_slug}"]) * 100.0 for item in target_rows]
        ax.plot(
            target_x,
            target_y,
            linestyle=LINESTYLES["Target Schedule"],
            linewidth=1.8,
            label=f"{asset} target",
            color=PALETTE["Target Schedule"],
            alpha=0.9,
        )
        ax.set_ylabel(f"{asset} Weight %")
        ax.grid(True, alpha=0.25)
        if idx == 0:
            ax.set_title(f"{title_prefix} | Weight Trajectory By Asset")
        if idx == len(assets) - 1:
            ax.set_xlabel("Date")

    axes[0].legend(loc="upper left", ncol=3, fontsize=8.5)
    axes[-1].xaxis.set_major_locator(mdates.MonthLocator(interval=3))
    axes[-1].xaxis.set_major_formatter(mdates.DateFormatter("%Y-%m"))
    fig.autofmt_xdate()
    fig.tight_layout()
    fig.savefig(output_path, dpi=180)
    plt.close(fig)
