from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import date


EPSILON = 1e-12


def clamp(value: float, lower: float, upper: float) -> float:
    return max(lower, min(upper, value))


def smoothstep(tau: float) -> float:
    tau = clamp(tau, 0.0, 1.0)
    return 3.0 * (tau ** 2) - 2.0 * (tau ** 3)


def normalize_weights(weights: list[float]) -> list[float]:
    total = sum(weights)
    if total <= EPSILON:
        raise ValueError("Weight vector sum must be positive.")
    return [weight / total for weight in weights]


def weights_to_string(assets: tuple[str, ...], weights: list[float]) -> str:
    return "|".join(f"{asset}:{weight:.6f}" for asset, weight in zip(assets, weights, strict=True))


def target_units(total_value: float, weights: list[float], prices: list[float]) -> list[float]:
    return [(total_value * weight) / price for weight, price in zip(weights, prices, strict=True)]


def portfolio_value(units: list[float], prices: list[float]) -> float:
    return sum(unit * price for unit, price in zip(units, prices, strict=True))


def actual_weights(units: list[float], prices: list[float]) -> list[float]:
    total_value = portfolio_value(units, prices)
    if total_value <= EPSILON:
        return [1.0 / len(units)] * len(units)
    return [(unit * price) / total_value for unit, price in zip(units, prices, strict=True)]


def composition_distance(weights_a: list[float], weights_b: list[float]) -> float:
    return 0.5 * sum(abs(a - b) for a, b in zip(weights_a, weights_b, strict=True))


def turnover_notional(current_units: list[float], target_units_: list[float], prices: list[float]) -> float:
    return 0.5 * sum(
        abs(target_unit - current_unit) * price
        for current_unit, target_unit, price in zip(current_units, target_units_, prices, strict=True)
    )


def weighted_equilibrium_transition(
    current_units: list[float],
    target_weights: list[float],
    prices: list[float],
) -> tuple[float, list[float], float]:
    if any(weight <= 0.0 for weight in target_weights):
        raise ValueError("Target weights must all be positive.")

    invariant_log = sum(
        weight * math.log(max(unit, EPSILON))
        for unit, weight in zip(current_units, target_weights, strict=True)
    )
    denominator_log = sum(
        weight * math.log(max(weight, EPSILON))
        for weight in target_weights
    )
    price_term_log = sum(
        weight * math.log(max(price, EPSILON))
        for price, weight in zip(prices, target_weights, strict=True)
    )
    no_fee_value = math.exp(invariant_log + price_term_log - denominator_log)
    target_units_ = target_units(no_fee_value, target_weights, prices)
    turnover = turnover_notional(current_units, target_units_, prices)
    return no_fee_value, target_units_, turnover


def convex_mix_weights(current: list[float], desired: list[float], alpha: float) -> list[float]:
    return normalize_weights(
        [
            (1.0 - alpha) * current_weight + alpha * desired_weight
            for current_weight, desired_weight in zip(current, desired, strict=True)
        ]
    )


def limit_weight_step(
    current_weights: list[float],
    desired_weights: list[float],
    max_step_delta: float,
) -> tuple[list[float], bool]:
    max_diff = max(abs(desired - current) for current, desired in zip(current_weights, desired_weights, strict=True))
    if max_diff <= max_step_delta + EPSILON:
        return desired_weights[:], False
    alpha = max_step_delta / max_diff
    return convex_mix_weights(current_weights, desired_weights, alpha), True


def implied_turnover_for_weights(
    units: list[float],
    weights: list[float],
    prices: list[float],
) -> float:
    total_value = portfolio_value(units, prices)
    target_units_ = target_units(total_value, weights, prices)
    return turnover_notional(units, target_units_, prices)


def limit_weight_by_turnover_cap(
    units: list[float],
    current_weights: list[float],
    desired_weights: list[float],
    prices: list[float],
    max_turnover_fraction: float,
) -> tuple[list[float], bool]:
    total_value = portfolio_value(units, prices)
    max_turnover = total_value * max_turnover_fraction
    desired_turnover = implied_turnover_for_weights(units, desired_weights, prices)
    if desired_turnover <= max_turnover + EPSILON:
        return desired_weights[:], False

    left = 0.0
    right = 1.0
    for _ in range(40):
        mid = 0.5 * (left + right)
        candidate = convex_mix_weights(current_weights, desired_weights, mid)
        turnover = implied_turnover_for_weights(units, candidate, prices)
        if turnover <= max_turnover:
            left = mid
        else:
            right = mid
    return convex_mix_weights(current_weights, desired_weights, left), True


@dataclass
class StrategyState:
    name: str
    assets: tuple[str, ...]
    units: list[float]
    active_weights: list[float]
    lifecycle: str = "Idle"
    cumulative_turnover_usd: float = 0.0
    cumulative_explicit_cost_usd: float = 0.0
    cumulative_implicit_cost_usd: float = 0.0
    cumulative_fee_income_usd: float = 0.0
    cumulative_net_cost_usd: float = 0.0
    rebalance_count: int = 0
    schedule_start_weights: list[float] | None = None
    schedule_target_weights: list[float] | None = None
    schedule_start_index: int | None = None
    schedule_end_index: int | None = None
    last_sync_index: int | None = None
    last_schedule_index: int | None = None
    cooldown_until_index: int | None = None
    drift_trigger_armed: bool = True

    def total_value(self, prices: list[float]) -> float:
        return portfolio_value(self.units, prices)

    def actual_weights(self, prices: list[float]) -> list[float]:
        return actual_weights(self.units, prices)


@dataclass
class RebalanceEvent:
    day: date
    strategy: str
    event_type: str
    lifecycle_after: str
    pre_value_usd: float
    post_value_usd: float
    turnover_usd: float
    explicit_cost_usd: float
    implicit_cost_usd: float
    fee_income_usd: float
    net_cost_usd: float
    fee_rate_bps_applied: float
    policy_weights: str
    scheduled_weights: str
    active_weights_after: str
    actual_weights_after: str
    trigger_type: str = ""
    step_cap_applied: bool = False
    turnover_cap_applied: bool = False
    schedule_drift_bps: float = 0.0

    def to_row(self) -> dict[str, object]:
        return {
            "date": self.day.isoformat(),
            "strategy": self.strategy,
            "event_type": self.event_type,
            "lifecycle_after": self.lifecycle_after,
            "pre_value_usd": self.pre_value_usd,
            "post_value_usd": self.post_value_usd,
            "turnover_usd": self.turnover_usd,
            "explicit_cost_usd": self.explicit_cost_usd,
            "implicit_cost_usd": self.implicit_cost_usd,
            "fee_income_usd": self.fee_income_usd,
            "net_cost_usd": self.net_cost_usd,
            "fee_rate_bps_applied": self.fee_rate_bps_applied,
            "policy_weights": self.policy_weights,
            "scheduled_weights": self.scheduled_weights,
            "active_weights_after": self.active_weights_after,
            "actual_weights_after": self.actual_weights_after,
            "trigger_type": self.trigger_type,
            "step_cap_applied": self.step_cap_applied,
            "turnover_cap_applied": self.turnover_cap_applied,
            "schedule_drift_bps": self.schedule_drift_bps,
        }


def apply_event_metrics(state: StrategyState, event: RebalanceEvent) -> None:
    state.cumulative_turnover_usd += event.turnover_usd
    state.cumulative_explicit_cost_usd += event.explicit_cost_usd
    state.cumulative_implicit_cost_usd += event.implicit_cost_usd
    state.cumulative_fee_income_usd += event.fee_income_usd
    state.cumulative_net_cost_usd += event.net_cost_usd
    if event.turnover_usd > EPSILON:
        state.rebalance_count += 1


def build_event(
    *,
    state: StrategyState,
    day: date,
    event_type: str,
    pre_value: float,
    post_value: float,
    turnover: float,
    explicit_cost: float,
    implicit_cost: float,
    fee_income: float,
    fee_rate_bps: float,
    policy_weights: list[float],
    scheduled_weights: list[float],
    prices: list[float],
    trigger_type: str = "",
    step_cap_applied: bool = False,
    turnover_cap_applied: bool = False,
    schedule_drift_bps: float = 0.0,
) -> RebalanceEvent:
    return RebalanceEvent(
        day=day,
        strategy=state.name,
        event_type=event_type,
        lifecycle_after=state.lifecycle,
        pre_value_usd=pre_value,
        post_value_usd=post_value,
        turnover_usd=turnover,
        explicit_cost_usd=explicit_cost,
        implicit_cost_usd=implicit_cost,
        fee_income_usd=fee_income,
        net_cost_usd=pre_value - post_value,
        fee_rate_bps_applied=fee_rate_bps,
        policy_weights=weights_to_string(state.assets, policy_weights),
        scheduled_weights=weights_to_string(state.assets, scheduled_weights),
        active_weights_after=weights_to_string(state.assets, state.active_weights),
        actual_weights_after=weights_to_string(state.assets, state.actual_weights(prices)),
        trigger_type=trigger_type,
        step_cap_applied=step_cap_applied,
        turnover_cap_applied=turnover_cap_applied,
        schedule_drift_bps=schedule_drift_bps,
    )


def apply_passive_swap_rebalance(
    state: StrategyState,
    day: date,
    policy_weights: list[float],
    prices: list[float],
    swap_fee_bps: float,
) -> RebalanceEvent:
    pre_value = state.total_value(prices)
    no_fee_value, _, turnover = weighted_equilibrium_transition(state.units, policy_weights, prices)
    fee_income = turnover * (swap_fee_bps / 10_000.0)
    post_value = no_fee_value + fee_income
    state.units = target_units(post_value, policy_weights, prices)
    state.active_weights = policy_weights[:]
    state.lifecycle = "Idle"
    implicit_cost = max(pre_value - no_fee_value, 0.0)
    return build_event(
        state=state,
        day=day,
        event_type="instant_rebalance",
        pre_value=pre_value,
        post_value=post_value,
        turnover=turnover,
        explicit_cost=0.0,
        implicit_cost=implicit_cost,
        fee_income=fee_income,
        fee_rate_bps=swap_fee_bps,
        policy_weights=policy_weights,
        scheduled_weights=policy_weights,
        prices=prices,
        trigger_type="calendar",
    )


def apply_dutch_auction_rebalance(
    state: StrategyState,
    day: date,
    policy_weights: list[float],
    prices: list[float],
    clearing_discount_bps: float,
    operational_cost_bps: float,
) -> RebalanceEvent:
    pre_value = state.total_value(prices)
    target_units_before_cost = target_units(pre_value, policy_weights, prices)
    turnover = turnover_notional(state.units, target_units_before_cost, prices)
    cost_rate = (clearing_discount_bps + operational_cost_bps) / 10_000.0
    explicit_cost = turnover * cost_rate
    post_value = pre_value - explicit_cost
    state.units = target_units(post_value, policy_weights, prices)
    state.active_weights = policy_weights[:]
    state.lifecycle = "Idle"
    return build_event(
        state=state,
        day=day,
        event_type="auction_rebalance",
        pre_value=pre_value,
        post_value=post_value,
        turnover=turnover,
        explicit_cost=explicit_cost,
        implicit_cost=0.0,
        fee_income=0.0,
        fee_rate_bps=(clearing_discount_bps + operational_cost_bps),
        policy_weights=policy_weights,
        scheduled_weights=policy_weights,
        prices=prices,
        trigger_type="calendar",
    )


def apply_manager_active_rebalance(
    state: StrategyState,
    day: date,
    policy_weights: list[float],
    prices: list[float],
    base_fee_bps: float,
    slippage_bps_multiplier: float,
    impact_bps_quadratic: float,
) -> RebalanceEvent:
    pre_value = state.total_value(prices)
    target_units_before_cost = target_units(pre_value, policy_weights, prices)
    turnover = turnover_notional(state.units, target_units_before_cost, prices)
    turnover_fraction = 0.0 if pre_value <= EPSILON else turnover / pre_value
    cost_rate = (
        base_fee_bps / 10_000.0
        + (slippage_bps_multiplier / 10_000.0) * turnover_fraction
        + (impact_bps_quadratic / 10_000.0) * (turnover_fraction ** 2)
    )
    explicit_cost = turnover * cost_rate
    post_value = pre_value - explicit_cost
    state.units = target_units(post_value, policy_weights, prices)
    state.active_weights = policy_weights[:]
    state.lifecycle = "Idle"
    return build_event(
        state=state,
        day=day,
        event_type="manager_rebalance",
        pre_value=pre_value,
        post_value=post_value,
        turnover=turnover,
        explicit_cost=explicit_cost,
        implicit_cost=0.0,
        fee_income=0.0,
        fee_rate_bps=cost_rate * 10_000.0,
        policy_weights=policy_weights,
        scheduled_weights=policy_weights,
        prices=prices,
        trigger_type="calendar",
    )


def release_cooldown_if_elapsed(state: StrategyState, day_index: int) -> None:
    if state.lifecycle == "Cooldown" and state.cooldown_until_index is not None and day_index >= state.cooldown_until_index:
        state.lifecycle = "Idle"
        state.cooldown_until_index = None


def maybe_schedule_passive_damped_rebalance(
    state: StrategyState,
    day: date,
    day_index: int,
    policy_weights: list[float],
    prices: list[float],
    rebalance_window_days: int,
    cooldown_days: int,
    min_rebalance_interval_days: int,
    drift_trigger_bps: float,
    hysteresis_bps: float,
    max_step_weight_delta_bps: float,
    max_turnover_bps: float,
    calendar_due: bool,
) -> RebalanceEvent | None:
    actual = state.actual_weights(prices)
    drift_to_policy = composition_distance(actual, policy_weights)
    drift_trigger = drift_trigger_bps / 10_000.0
    hysteresis = hysteresis_bps / 10_000.0
    max_step_delta = max_step_weight_delta_bps / 10_000.0
    max_turnover_fraction = max_turnover_bps / 10_000.0

    if drift_to_policy <= max(drift_trigger - hysteresis, 0.0):
        state.drift_trigger_armed = True

    if state.lifecycle in {"Scheduled", "Active", "Settling"}:
        return None
    if state.cooldown_until_index is not None and day_index < state.cooldown_until_index:
        return None
    if state.last_schedule_index is not None and day_index - state.last_schedule_index < min_rebalance_interval_days:
        return None

    drift_due = drift_to_policy >= drift_trigger and state.drift_trigger_armed
    if not calendar_due and not drift_due:
        return None

    stepped_target, step_cap_applied = limit_weight_step(state.active_weights, policy_weights, max_step_delta)
    capped_target, turnover_cap_applied = limit_weight_by_turnover_cap(
        state.units,
        state.active_weights,
        stepped_target,
        prices,
        max_turnover_fraction,
    )
    if composition_distance(capped_target, state.active_weights) <= EPSILON:
        return None

    state.schedule_start_weights = state.active_weights[:]
    state.schedule_target_weights = capped_target[:]
    state.schedule_start_index = day_index
    state.schedule_end_index = day_index + max(rebalance_window_days, 1)
    state.last_sync_index = day_index - 1
    state.last_schedule_index = day_index
    state.cooldown_until_index = day_index + cooldown_days
    state.lifecycle = "Scheduled"
    if drift_due:
        state.drift_trigger_armed = False

    trigger_type = "calendar+drift" if calendar_due and drift_due else ("calendar" if calendar_due else "drift")
    value = state.total_value(prices)
    return build_event(
        state=state,
        day=day,
        event_type="schedule",
        pre_value=value,
        post_value=value,
        turnover=0.0,
        explicit_cost=0.0,
        implicit_cost=0.0,
        fee_income=0.0,
        fee_rate_bps=0.0,
        policy_weights=policy_weights,
        scheduled_weights=capped_target,
        prices=prices,
        trigger_type=trigger_type,
        step_cap_applied=step_cap_applied,
        turnover_cap_applied=turnover_cap_applied,
        schedule_drift_bps=drift_to_policy * 10_000.0,
    )


def apply_passive_damped_step(
    state: StrategyState,
    day: date,
    day_index: int,
    policy_weights: list[float],
    prices: list[float],
    beta_max: float,
    mu: float,
    kappa: float,
    fee_min_bps: float,
    fee_mid_bps: float,
    fee_max_bps: float,
    epsilon_bps: float,
) -> RebalanceEvent | None:
    if state.lifecycle not in {"Scheduled", "Active", "Settling"}:
        return None
    if (
        state.schedule_start_weights is None
        or state.schedule_target_weights is None
        or state.schedule_start_index is None
        or state.schedule_end_index is None
    ):
        return None

    pre_value = state.total_value(prices)
    actual_before = state.actual_weights(prices)
    active_before = state.active_weights[:]

    total_window = max(state.schedule_end_index - state.schedule_start_index, 1)
    tau = (day_index - state.schedule_start_index) / total_window
    path_weights = normalize_weights(
        [
            (1.0 - smoothstep(tau)) * start_weight + smoothstep(tau) * target_weight
            for start_weight, target_weight in zip(state.schedule_start_weights, state.schedule_target_weights, strict=True)
        ]
    )

    error = composition_distance(actual_before, path_weights)
    last_sync_index = state.last_sync_index if state.last_sync_index is not None else (day_index - 1)
    dt = max(day_index - last_sync_index, 1)
    beta = min(beta_max, (1.0 - math.exp(-mu * dt)) * (1.0 / (1.0 + kappa * error)))
    effective_weights = normalize_weights(
        [
            (1.0 - beta) * current_weight + beta * path_weight
            for current_weight, path_weight in zip(state.active_weights, path_weights, strict=True)
        ]
    )

    no_fee_value, _, turnover = weighted_equilibrium_transition(state.units, effective_weights, prices)
    quality_before = 0.7 * composition_distance(actual_before, path_weights) + 0.3 * composition_distance(actual_before, state.schedule_target_weights)
    quality_after = 0.7 * composition_distance(effective_weights, path_weights) + 0.3 * composition_distance(effective_weights, state.schedule_target_weights)
    if quality_before <= EPSILON:
        fee_bps = fee_min_bps
    elif quality_after <= quality_before:
        improvement = clamp((quality_before - quality_after) / quality_before, 0.0, 1.0)
        fee_bps = fee_mid_bps - (fee_mid_bps - fee_min_bps) * improvement
    else:
        worsening = clamp((quality_after - quality_before) / max(quality_before, 1e-4), 0.0, 1.0)
        fee_bps = fee_mid_bps + (fee_max_bps - fee_mid_bps) * worsening

    fee_income = turnover * (fee_bps / 10_000.0)
    post_value = no_fee_value + fee_income
    state.units = target_units(post_value, effective_weights, prices)
    state.active_weights = effective_weights
    state.last_sync_index = day_index

    epsilon = epsilon_bps / 10_000.0
    target_gap = composition_distance(state.active_weights, state.schedule_target_weights)
    if day_index >= state.schedule_end_index and target_gap <= epsilon:
        state.lifecycle = "Cooldown"
        state.schedule_start_weights = None
        state.schedule_target_weights = None
        state.schedule_start_index = None
        state.schedule_end_index = None
        state.last_sync_index = None
    elif day_index >= state.schedule_end_index:
        state.lifecycle = "Settling"
    else:
        state.lifecycle = "Active"

    implicit_cost = max(pre_value - no_fee_value, 0.0)
    return build_event(
        state=state,
        day=day,
        event_type="damped_sync",
        pre_value=pre_value,
        post_value=post_value,
        turnover=turnover,
        explicit_cost=0.0,
        implicit_cost=implicit_cost,
        fee_income=fee_income,
        fee_rate_bps=fee_bps,
        policy_weights=policy_weights,
        scheduled_weights=state.schedule_target_weights or effective_weights,
        prices=prices,
        trigger_type="sync",
        schedule_drift_bps=composition_distance(actual_before, policy_weights) * 10_000.0,
    )
