from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence


BPS = 10_000.0
EPSILON = 1e-12


def portfolio_value(units: Sequence[float], prices: Sequence[float]) -> float:
    return sum(unit * price for unit, price in zip(units, prices, strict=True))


def weights(units: Sequence[float], prices: Sequence[float]) -> list[float]:
    total = portfolio_value(units, prices)
    if total <= EPSILON:
        raise ValueError("Portfolio value must be positive.")
    return [unit * price / total for unit, price in zip(units, prices, strict=True)]


def drift_bps(units: Sequence[float], prices: Sequence[float], target: Sequence[float]) -> float:
    actual = weights(units, prices)
    return 0.5 * sum(abs(current - desired) for current, desired in zip(actual, target, strict=True)) * BPS


def units_for_weights(total_value: float, target: Sequence[float], prices: Sequence[float]) -> list[float]:
    return [total_value * weight / price for weight, price in zip(target, prices, strict=True)]


def turnover_notional(
    current_units: Sequence[float], target_units: Sequence[float], prices: Sequence[float]
) -> float:
    return 0.5 * sum(
        abs(target - current) * price
        for current, target, price in zip(current_units, target_units, prices, strict=True)
    )


def validate_weights(target: Sequence[float], asset_count: int) -> None:
    if len(target) != asset_count or any(weight <= 0.0 for weight in target):
        raise ValueError("Target weights must be positive and match the asset count.")
    if abs(sum(target) - 1.0) > 1e-9:
        raise ValueError("Target weights must sum to one.")


@dataclass(frozen=True)
class AuctionPolicy:
    name: str
    trigger_bps: float
    destination_bps: float
    min_plan_interval_days: int
    plan_duration_days: int
    opening_delay_days: int
    auction_duration_days: int
    max_turnover_bps: float
    max_asset_adjustment_bps: float
    start_premium_bps: float
    max_discount_bps: float

    def __post_init__(self) -> None:
        if not 0.0 <= self.destination_bps < self.trigger_bps:
            raise ValueError("Destination drift must be below trigger drift.")
        if (
            self.min_plan_interval_days < 0
            or self.opening_delay_days < 0
            or self.auction_duration_days <= 0
            or self.plan_duration_days <= 0
        ):
            raise ValueError("Policy timing values are invalid.")
        if self.opening_delay_days + self.auction_duration_days > self.plan_duration_days:
            raise ValueError("The plan must contain the complete auction window.")
        for value in (
            self.max_turnover_bps,
            self.max_asset_adjustment_bps,
            self.start_premium_bps,
            self.max_discount_bps,
        ):
            if value < 0.0 or value > BPS:
                raise ValueError("Policy BPS values must be bounded.")


@dataclass(frozen=True)
class ExecutionStress:
    name: str
    daily_fill_fraction: float
    daily_liquidity_usd: float
    hedge_cost_bps: float
    gas_cost_usd: float
    oracle_outage_days: tuple[int, ...] = ()
    config_invalidation_days: tuple[int, ...] = ()

    def __post_init__(self) -> None:
        if not 0.0 <= self.daily_fill_fraction <= 1.0:
            raise ValueError("Daily fill fraction must be between zero and one.")
        if self.daily_liquidity_usd < 0.0 or self.hedge_cost_bps < 0.0 or self.gas_cost_usd < 0.0:
            raise ValueError("Execution assumptions cannot be negative.")


@dataclass
class Plan:
    opened_day: int
    auction_start_day: int
    auction_end_day: int
    expires_day: int
    target_units: list[float]
    target_weights: list[float]
    initial_turnover_usd: float
    remaining_turnover_usd: float


@dataclass
class SimulationMetrics:
    plans_started: int = 0
    plans_finalized: int = 0
    plans_expired: int = 0
    plans_invalidated: int = 0
    fills: int = 0
    zero_fill_days: int = 0
    cumulative_turnover_usd: float = 0.0
    cumulative_execution_cost_usd: float = 0.0
    cumulative_gas_cost_usd: float = 0.0
    expired_unfilled_usd: float = 0.0
    invalidated_unfilled_usd: float = 0.0
    max_all_in_cost_bps: float = 0.0
    total_completion_days: int = 0


@dataclass(frozen=True)
class SimulationResult:
    strategy: str
    stress: str
    initial_aum_usd: float
    final_value_usd: float
    average_drift_bps: float
    max_drift_bps: float
    final_drift_bps: float
    unfilled_notional_usd: float
    metrics: SimulationMetrics

    def to_row(self) -> dict[str, object]:
        completed = self.metrics.plans_finalized
        started = self.metrics.plans_started
        return {
            "strategy": self.strategy,
            "stress": self.stress,
            "initial_aum_usd": self.initial_aum_usd,
            "final_value_usd": self.final_value_usd,
            "return_pct": (self.final_value_usd / self.initial_aum_usd - 1.0) * 100.0,
            "average_drift_bps": self.average_drift_bps,
            "max_drift_bps": self.max_drift_bps,
            "final_drift_bps": self.final_drift_bps,
            "turnover_usd": self.metrics.cumulative_turnover_usd,
            "execution_cost_usd": self.metrics.cumulative_execution_cost_usd,
            "gas_cost_usd": self.metrics.cumulative_gas_cost_usd,
            "plans_started": started,
            "plans_finalized": completed,
            "plans_expired": self.metrics.plans_expired,
            "plans_invalidated": self.metrics.plans_invalidated,
            "completion_rate_pct": 0.0 if started == 0 else completed / started * 100.0,
            "average_completion_days": 0.0 if completed == 0 else self.metrics.total_completion_days / completed,
            "fills": self.metrics.fills,
            "zero_fill_days": self.metrics.zero_fill_days,
            "max_all_in_cost_bps": self.metrics.max_all_in_cost_bps,
            "unfilled_notional_usd": self.unfilled_notional_usd,
            "expired_unfilled_usd": self.metrics.expired_unfilled_usd,
            "invalidated_unfilled_usd": self.metrics.invalidated_unfilled_usd,
        }


def scaled_plan_target(
    units: Sequence[float],
    prices: Sequence[float],
    target: Sequence[float],
    policy: AuctionPolicy,
) -> tuple[list[float], float, float]:
    validate_weights(target, len(units))
    total = portfolio_value(units, prices)
    desired = units_for_weights(total, target, prices)
    deltas = [(goal - current) * price for current, goal, price in zip(units, desired, prices, strict=True)]
    required_turnover = 0.5 * sum(abs(delta) for delta in deltas)
    if required_turnover <= EPSILON:
        return list(units), 0.0, 1.0

    turnover_cap = total * policy.max_turnover_bps / BPS
    asset_cap = total * policy.max_asset_adjustment_bps / BPS
    largest_adjustment = max(abs(delta) for delta in deltas)
    scale = min(1.0, turnover_cap / required_turnover, asset_cap / largest_adjustment)
    target_units = [current + scale * (goal - current) for current, goal in zip(units, desired, strict=True)]
    return target_units, turnover_notional(units, target_units, prices), scale


def current_policy(schedule: dict[int, Sequence[float]], day: int) -> list[float]:
    eligible = [scheduled_day for scheduled_day in schedule if scheduled_day <= day]
    if not eligible:
        raise ValueError("Policy schedule must start on or before the first simulated day.")
    return list(schedule[max(eligible)])


class AuctionSimulator:
    def __init__(self, policy: AuctionPolicy, stress: ExecutionStress) -> None:
        self.policy = policy
        self.stress = stress

    def run(
        self,
        price_path: Sequence[Sequence[float]],
        policy_schedule: dict[int, Sequence[float]],
        initial_aum_usd: float,
    ) -> SimulationResult:
        if not price_path or initial_aum_usd <= 0.0:
            raise ValueError("A positive AUM and non-empty price path are required.")
        asset_count = len(price_path[0])
        invalid_path = any(
            len(prices) != asset_count or any(price <= 0.0 for price in prices)
            for prices in price_path
        )
        if asset_count < 2 or invalid_path:
            raise ValueError("Every price row must contain the same positive asset prices.")

        initial_target = current_policy(policy_schedule, 0)
        validate_weights(initial_target, asset_count)
        units = units_for_weights(initial_aum_usd, initial_target, price_path[0])
        metrics = SimulationMetrics()
        plan: Plan | None = None
        last_plan_day: int | None = None
        drift_samples: list[float] = []

        for day, raw_prices in enumerate(price_path):
            prices = list(raw_prices)
            target = current_policy(policy_schedule, day)
            validate_weights(target, asset_count)

            if plan is not None:
                if day in self.stress.config_invalidation_days:
                    metrics.plans_invalidated += 1
                    metrics.invalidated_unfilled_usd += plan.remaining_turnover_usd
                    plan = None
                elif day > plan.auction_end_day or day > plan.expires_day:
                    metrics.plans_expired += 1
                    metrics.expired_unfilled_usd += plan.remaining_turnover_usd
                    plan = None
                elif day >= plan.auction_start_day:
                    units, plan = self._process_auction_day(day, units, prices, plan, metrics)

            calendar_due = day in policy_schedule and day != 0
            drift_due = drift_bps(units, prices, target) >= self.policy.trigger_bps
            interval_ready = last_plan_day is None or day - last_plan_day >= self.policy.min_plan_interval_days
            if plan is None and interval_ready and (calendar_due or drift_due):
                target_units, turnover, _ = scaled_plan_target(units, prices, target, self.policy)
                if turnover > EPSILON:
                    plan = Plan(
                        opened_day=day,
                        auction_start_day=day + self.policy.opening_delay_days,
                        auction_end_day=(
                            day + self.policy.opening_delay_days + self.policy.auction_duration_days
                        ),
                        expires_day=day + self.policy.plan_duration_days,
                        target_units=target_units,
                        target_weights=target,
                        initial_turnover_usd=turnover,
                        remaining_turnover_usd=turnover,
                    )
                    metrics.plans_started += 1
                    last_plan_day = day
                    if self.policy.opening_delay_days == 0:
                        units, plan = self._process_auction_day(day, units, prices, plan, metrics)

            drift_samples.append(drift_bps(units, prices, target))

        final_prices = list(price_path[-1])
        final_target = current_policy(policy_schedule, len(price_path) - 1)
        return SimulationResult(
            strategy=self.policy.name,
            stress=self.stress.name,
            initial_aum_usd=initial_aum_usd,
            final_value_usd=portfolio_value(units, final_prices),
            average_drift_bps=sum(drift_samples) / len(drift_samples),
            max_drift_bps=max(drift_samples),
            final_drift_bps=drift_bps(units, final_prices, final_target),
            unfilled_notional_usd=(
                metrics.expired_unfilled_usd
                + metrics.invalidated_unfilled_usd
                + (0.0 if plan is None else plan.remaining_turnover_usd)
            ),
            metrics=metrics,
        )

    def _process_auction_day(
        self,
        day: int,
        units: list[float],
        prices: list[float],
        plan: Plan,
        metrics: SimulationMetrics,
    ) -> tuple[list[float], Plan | None]:
        if day in self.stress.oracle_outage_days or self.stress.daily_fill_fraction <= EPSILON:
            metrics.zero_fill_days += 1
            return units, plan

        live_remaining = turnover_notional(units, plan.target_units, prices)
        if live_remaining <= EPSILON:
            self._finalize(day, plan, metrics)
            return units, None

        fill_notional = min(
            live_remaining,
            plan.remaining_turnover_usd,
            self.stress.daily_liquidity_usd,
            live_remaining * self.stress.daily_fill_fraction,
        )
        if fill_notional <= EPSILON:
            metrics.zero_fill_days += 1
            return units, plan

        alpha = fill_notional / live_remaining
        pre_value = portfolio_value(units, prices)
        gross_units = [
            current + alpha * (target - current)
            for current, target in zip(units, plan.target_units, strict=True)
        ]
        gross_value = portfolio_value(gross_units, prices)
        gross_units = [unit * pre_value / gross_value for unit in gross_units]

        auction_days = max(plan.auction_end_day - plan.auction_start_day, 1)
        progress = min(max((day - plan.auction_start_day) / auction_days, 0.0), 1.0)
        curve_discount = -self.policy.start_premium_bps + progress * (
            self.policy.start_premium_bps + self.policy.max_discount_bps
        )
        execution_bps = max(curve_discount + self.stress.hedge_cost_bps, 0.0)
        variable_cost = fill_notional * execution_bps / BPS
        total_cost = min(variable_cost + self.stress.gas_cost_usd, pre_value * 0.99)
        post_value = pre_value - total_cost
        units = [unit * post_value / pre_value for unit in gross_units]

        metrics.fills += 1
        metrics.cumulative_turnover_usd += fill_notional
        metrics.cumulative_execution_cost_usd += total_cost
        metrics.cumulative_gas_cost_usd += self.stress.gas_cost_usd
        metrics.max_all_in_cost_bps = max(metrics.max_all_in_cost_bps, execution_bps)

        plan.remaining_turnover_usd -= fill_notional
        if plan.remaining_turnover_usd <= max(plan.initial_turnover_usd * 1e-6, 1e-6):
            self._finalize(day, plan, metrics)
            return units, None
        if drift_bps(units, prices, plan.target_weights) <= self.policy.destination_bps:
            self._finalize(day, plan, metrics)
            return units, None
        return units, plan

    @staticmethod
    def _finalize(day: int, plan: Plan, metrics: SimulationMetrics) -> None:
        metrics.plans_finalized += 1
        metrics.total_completion_days += day - plan.opened_day


def simulate_direct_rebalance(
    name: str,
    price_path: Sequence[Sequence[float]],
    policy_schedule: dict[int, Sequence[float]],
    initial_aum_usd: float,
    trigger_bps: float | None,
    cost_bps: float,
    rebalance_on_calendar: bool = True,
) -> SimulationResult:
    initial_target = current_policy(policy_schedule, 0)
    units = units_for_weights(initial_aum_usd, initial_target, price_path[0])
    metrics = SimulationMetrics()
    drift_samples: list[float] = []

    for day, raw_prices in enumerate(price_path):
        prices = list(raw_prices)
        target = current_policy(policy_schedule, day)
        calendar_due = rebalance_on_calendar and day in policy_schedule and day != 0
        threshold_due = trigger_bps is not None and drift_bps(units, prices, target) >= trigger_bps
        if calendar_due or threshold_due:
            pre_value = portfolio_value(units, prices)
            desired = units_for_weights(pre_value, target, prices)
            turnover = turnover_notional(units, desired, prices)
            if turnover > EPSILON:
                cost = turnover * cost_bps / BPS
                units = units_for_weights(pre_value - cost, target, prices)
                metrics.plans_started += 1
                metrics.plans_finalized += 1
                metrics.fills += 1
                metrics.cumulative_turnover_usd += turnover
                metrics.cumulative_execution_cost_usd += cost
        drift_samples.append(drift_bps(units, prices, target))

    final_prices = list(price_path[-1])
    final_target = current_policy(policy_schedule, len(price_path) - 1)
    return SimulationResult(
        strategy=name,
        stress="Benchmark",
        initial_aum_usd=initial_aum_usd,
        final_value_usd=portfolio_value(units, final_prices),
        average_drift_bps=sum(drift_samples) / len(drift_samples),
        max_drift_bps=max(drift_samples),
        final_drift_bps=drift_bps(units, final_prices, final_target),
        unfilled_notional_usd=0.0,
        metrics=metrics,
    )
