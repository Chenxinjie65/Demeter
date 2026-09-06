from __future__ import annotations

from dataclasses import dataclass
from datetime import date
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent
DATA_DIR = ROOT_DIR / "data"
OUTPUT_DIR = ROOT_DIR / "output"

GLOBAL_START_DATE = date(2022, 1, 1)
GLOBAL_END_DATE = date(2025, 12, 31)

INITIAL_AUM_USD = 10_000_000.0

COINGECKO_IDS = {
    "ETH": "ethereum",
    "BTC": "bitcoin",
    "SOL": "solana",
    "LINK": "chainlink",
}

YAHOO_SYMBOLS = {
    "ETH": "ETH-USD",
    "BTC": "BTC-USD",
    "SOL": "SOL-USD",
    "LINK": "LINK-USD",
}


@dataclass(frozen=True)
class WindowConfig:
    name: str
    start_date: date
    end_date: date


@dataclass(frozen=True)
class ScenarioConfig:
    name: str
    slug: str
    assets: tuple[str, ...]
    yearly_target_templates: tuple[tuple[int, int, tuple[float, ...]], ...]

    def target_schedule(self, start_year: int, end_year: int) -> dict[date, tuple[float, ...]]:
        schedule: dict[date, tuple[float, ...]] = {}
        for year in range(start_year, end_year + 1):
            for month, day, weights in self.yearly_target_templates:
                schedule[date(year, month, day)] = weights
        return schedule


WINDOWS: tuple[WindowConfig, ...] = (
    WindowConfig("2022", date(2022, 1, 1), date(2022, 12, 31)),
    WindowConfig("2023", date(2023, 1, 1), date(2023, 12, 31)),
    WindowConfig("2024", date(2024, 1, 1), date(2024, 12, 31)),
    WindowConfig("2025", date(2025, 1, 1), date(2025, 12, 31)),
    WindowConfig("2022_2023", date(2022, 1, 1), date(2023, 12, 31)),
    WindowConfig("2024_2025", date(2024, 1, 1), date(2025, 12, 31)),
    WindowConfig("2022_2025", date(2022, 1, 1), date(2025, 12, 31)),
)


SCENARIOS: tuple[ScenarioConfig, ...] = (
    ScenarioConfig(
        name="Dual Major Index",
        slug="dual_major",
        assets=("ETH", "BTC"),
        yearly_target_templates=(
            (1, 1, (0.50, 0.50)),
            (2, 1, (0.52, 0.48)),
            (3, 1, (0.48, 0.52)),
            (4, 1, (0.55, 0.45)),
            (5, 1, (0.45, 0.55)),
            (6, 1, (0.50, 0.50)),
            (7, 1, (0.53, 0.47)),
            (8, 1, (0.47, 0.53)),
            (9, 1, (0.51, 0.49)),
            (10, 1, (0.49, 0.51)),
            (11, 1, (0.54, 0.46)),
            (12, 1, (0.50, 0.50)),
        ),
    ),
    ScenarioConfig(
        name="Diversified Crypto 4",
        slug="diversified_crypto_4",
        assets=("ETH", "BTC", "SOL", "LINK"),
        yearly_target_templates=(
            (1, 1, (0.35, 0.35, 0.20, 0.10)),
            (3, 1, (0.33, 0.34, 0.22, 0.11)),
            (5, 1, (0.30, 0.36, 0.24, 0.10)),
            (7, 1, (0.32, 0.33, 0.25, 0.10)),
            (9, 1, (0.36, 0.34, 0.20, 0.10)),
            (11, 1, (0.34, 0.37, 0.18, 0.11)),
        ),
    ),
)


PASSIVE_SWAP_FEE_BPS = 30.0

AUCTION_CLEARING_DISCOUNT_BPS = 10.0
AUCTION_OPERATIONAL_COST_BPS = 2.0

ACTIVE_BASE_FEE_BPS = 5.0
ACTIVE_SLIPPAGE_BPS_MULTIPLIER = 20.0
ACTIVE_IMPACT_BPS_QUADRATIC = 30.0

DAMPED_REBALANCE_WINDOW_DAYS = 14
DAMPED_COOLDOWN_DAYS = 7
DAMPED_MIN_REBALANCE_INTERVAL_DAYS = 21
DAMPED_DRIFT_TRIGGER_BPS = 175.0
DAMPED_HYSTERESIS_BPS = 50.0
DAMPED_MAX_STEP_WEIGHT_DELTA_BPS = 300.0
DAMPED_MAX_TURNOVER_BPS = 1200.0
DAMPED_BETA_MAX = 0.35
DAMPED_MU = 0.75
DAMPED_KAPPA = 6.0
DAMPED_FEE_MIN_BPS = 6.0
DAMPED_FEE_MID_BPS = 18.0
DAMPED_FEE_MAX_BPS = 40.0
DAMPED_EPSILON_BPS = 20.0


@dataclass(frozen=True)
class StudyConfig:
    global_start_date: date = GLOBAL_START_DATE
    global_end_date: date = GLOBAL_END_DATE
    initial_aum_usd: float = INITIAL_AUM_USD
    windows: tuple[WindowConfig, ...] = WINDOWS
    scenarios: tuple[ScenarioConfig, ...] = SCENARIOS
    passive_swap_fee_bps: float = PASSIVE_SWAP_FEE_BPS
    auction_clearing_discount_bps: float = AUCTION_CLEARING_DISCOUNT_BPS
    auction_operational_cost_bps: float = AUCTION_OPERATIONAL_COST_BPS
    active_base_fee_bps: float = ACTIVE_BASE_FEE_BPS
    active_slippage_bps_multiplier: float = ACTIVE_SLIPPAGE_BPS_MULTIPLIER
    active_impact_bps_quadratic: float = ACTIVE_IMPACT_BPS_QUADRATIC
    damped_rebalance_window_days: int = DAMPED_REBALANCE_WINDOW_DAYS
    damped_cooldown_days: int = DAMPED_COOLDOWN_DAYS
    damped_min_rebalance_interval_days: int = DAMPED_MIN_REBALANCE_INTERVAL_DAYS
    damped_drift_trigger_bps: float = DAMPED_DRIFT_TRIGGER_BPS
    damped_hysteresis_bps: float = DAMPED_HYSTERESIS_BPS
    damped_max_step_weight_delta_bps: float = DAMPED_MAX_STEP_WEIGHT_DELTA_BPS
    damped_max_turnover_bps: float = DAMPED_MAX_TURNOVER_BPS
    damped_beta_max: float = DAMPED_BETA_MAX
    damped_mu: float = DAMPED_MU
    damped_kappa: float = DAMPED_KAPPA
    damped_fee_min_bps: float = DAMPED_FEE_MIN_BPS
    damped_fee_mid_bps: float = DAMPED_FEE_MID_BPS
    damped_fee_max_bps: float = DAMPED_FEE_MAX_BPS
    damped_epsilon_bps: float = DAMPED_EPSILON_BPS
