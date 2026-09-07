from __future__ import annotations

import unittest

from .v2_compare import default_policy_schedule, deterministic_price_path, run_comparison
from .v2_model import (
    AuctionPolicy,
    AuctionSimulator,
    ExecutionStress,
    scaled_plan_target,
    simulate_direct_rebalance,
)


class V2ModelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.policy = AuctionPolicy(
            name="Test",
            trigger_bps=100.0,
            destination_bps=25.0,
            min_plan_interval_days=1,
            plan_duration_days=3,
            opening_delay_days=0,
            max_turnover_bps=2_000.0,
            max_asset_adjustment_bps=1_000.0,
            start_premium_bps=20.0,
            max_discount_bps=100.0,
        )

    def test_uniform_plan_scaling_respects_turnover_and_asset_caps(self) -> None:
        units = [50.0, 50.0]
        prices = [1.0, 1.0]
        target_units, turnover, scale = scaled_plan_target(units, prices, [0.9, 0.1], self.policy)
        self.assertAlmostEqual(turnover, 10.0)
        self.assertAlmostEqual(scale, 0.25)
        self.assertEqual(target_units, [60.0, 40.0])

    def test_zero_fill_expires_without_cost_or_turnover(self) -> None:
        stress = ExecutionStress("Zero", 0.0, 0.0, 0.0, 0.0)
        prices = [[1.0, 1.0], [2.0, 1.0], [2.0, 1.0], [2.0, 1.0], [2.0, 1.0], [2.0, 1.0]]
        result = AuctionSimulator(self.policy, stress).run(prices, {0: (0.5, 0.5)}, 100.0)
        self.assertGreater(result.metrics.plans_started, 0)
        self.assertGreater(result.metrics.plans_expired, 0)
        self.assertEqual(result.metrics.cumulative_turnover_usd, 0.0)
        self.assertEqual(result.metrics.cumulative_execution_cost_usd, 0.0)
        self.assertGreater(result.metrics.expired_unfilled_usd, 0.0)
        self.assertGreaterEqual(result.unfilled_notional_usd, result.metrics.expired_unfilled_usd)

    def test_partial_fill_never_exceeds_plan_turnover(self) -> None:
        policy = AuctionPolicy(
            name="Single Plan",
            trigger_bps=100.0,
            destination_bps=25.0,
            min_plan_interval_days=100,
            plan_duration_days=3,
            opening_delay_days=0,
            max_turnover_bps=2_000.0,
            max_asset_adjustment_bps=1_000.0,
            start_premium_bps=20.0,
            max_discount_bps=100.0,
        )
        stress = ExecutionStress("Partial", 0.25, 5.0, 10.0, 1.0)
        prices = [[1.0, 1.0]] + [[2.0, 1.0]] * 8
        result = AuctionSimulator(policy, stress).run(prices, {0: (0.5, 0.5)}, 100.0)
        self.assertGreater(result.metrics.fills, 0)
        self.assertLessEqual(result.metrics.cumulative_turnover_usd, 15.0)
        self.assertGreater(result.metrics.cumulative_execution_cost_usd, 0.0)

    def test_healthy_liquidity_completes_with_bounded_all_in_cost(self) -> None:
        policy = AuctionPolicy(
            name="Single Plan",
            trigger_bps=100.0,
            destination_bps=25.0,
            min_plan_interval_days=100,
            plan_duration_days=3,
            opening_delay_days=0,
            max_turnover_bps=2_000.0,
            max_asset_adjustment_bps=1_000.0,
            start_premium_bps=20.0,
            max_discount_bps=100.0,
        )
        stress = ExecutionStress("Healthy", 1.0, 1_000.0, 10.0, 0.0)
        prices = [[1.0, 1.0]] + [[2.0, 1.0]] * 4
        result = AuctionSimulator(policy, stress).run(prices, {0: (0.5, 0.5)}, 100.0)
        self.assertEqual(result.metrics.plans_finalized, 1)
        self.assertEqual(result.metrics.plans_expired, 0)
        self.assertLessEqual(result.metrics.max_all_in_cost_bps, policy.max_discount_bps + 10.0)

    def test_oracle_outage_fails_closed(self) -> None:
        outage = tuple(range(1, 10))
        stress = ExecutionStress("Outage", 1.0, 1_000.0, 5.0, 0.0, oracle_outage_days=outage)
        prices = [[1.0, 1.0]] + [[2.0, 1.0]] * 8
        result = AuctionSimulator(self.policy, stress).run(prices, {0: (0.5, 0.5)}, 100.0)
        self.assertEqual(result.metrics.fills, 0)
        self.assertGreater(result.metrics.zero_fill_days, 0)
        self.assertGreater(result.metrics.plans_expired, 0)

    def test_config_change_invalidates_live_plan(self) -> None:
        stress = ExecutionStress("Invalidation", 0.2, 2.0, 5.0, 0.0, config_invalidation_days=(2,))
        prices = [[1.0, 1.0]] + [[2.0, 1.0]] * 6
        result = AuctionSimulator(self.policy, stress).run(prices, {0: (0.5, 0.5)}, 100.0)
        self.assertEqual(result.metrics.plans_invalidated, 1)
        self.assertGreater(result.metrics.invalidated_unfilled_usd, 0.0)

    def test_strategy_matrix_is_deterministic(self) -> None:
        first = [result.to_row() for result in run_comparison(120, 1_000_000.0)]
        second = [result.to_row() for result in run_comparison(120, 1_000_000.0)]
        self.assertEqual(first, second)
        self.assertEqual(len(first), 18)

    def test_default_path_and_schedule_cover_four_assets(self) -> None:
        path = deterministic_price_path(365)
        schedule = default_policy_schedule(365)
        self.assertEqual(len(path), 365)
        self.assertTrue(all(len(row) == 4 for row in path))
        self.assertEqual(sorted(schedule), [0, 90, 180, 270])

    def test_buy_and_hold_never_rebalances(self) -> None:
        prices = [[1.0, 1.0], [2.0, 1.0], [3.0, 1.0]]
        result = simulate_direct_rebalance(
            "Hold",
            prices,
            {0: (0.5, 0.5), 1: (0.8, 0.2)},
            100.0,
            trigger_bps=None,
            cost_bps=0.0,
            rebalance_on_calendar=False,
        )
        self.assertEqual(result.metrics.fills, 0)
        self.assertEqual(result.metrics.cumulative_turnover_usd, 0.0)
        self.assertAlmostEqual(result.final_value_usd, 200.0)


if __name__ == "__main__":
    unittest.main()
