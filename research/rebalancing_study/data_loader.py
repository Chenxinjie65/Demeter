from __future__ import annotations

import csv
import json
import time
from dataclasses import dataclass
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Iterable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .config import COINGECKO_IDS, DATA_DIR, GLOBAL_END_DATE, GLOBAL_START_DATE, YAHOO_SYMBOLS


COINGECKO_MARKET_CHART = (
    "https://api.coingecko.com/api/v3/coins/{coin_id}/market_chart"
    "?vs_currency=usd&days=max&interval=daily"
)

YAHOO_CHART_URL = (
    "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}"
    "?period1={period1}&period2={period2}&interval=1d&includeAdjustedClose=true"
)


@dataclass(frozen=True)
class MarketPoint:
    day: date
    prices: dict[str, float]


def asset_cache_path(asset: str) -> Path:
    return DATA_DIR / f"price_cache_{asset.lower()}.csv"


def load_asset_cache(cache_path: Path) -> dict[date, float]:
    with cache_path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        return {date.fromisoformat(row["date"]): float(row["price_usd"]) for row in reader}


def write_asset_cache(cache_path: Path, points: Iterable[tuple[date, float]]) -> None:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    with cache_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["date", "price_usd"])
        for day, price in sorted(points):
            writer.writerow([day.isoformat(), f"{price:.10f}"])


def fetch_price_series_from_coingecko(asset: str) -> dict[date, float]:
    coin_id = COINGECKO_IDS[asset]
    request = Request(
        COINGECKO_MARKET_CHART.format(coin_id=coin_id),
        headers={
            "accept": "application/json",
            "user-agent": "demeter-rebalancing-study/2.0",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        raise RuntimeError(f"CoinGecko request failed for {asset}: HTTP {exc.code}") from exc
    except URLError as exc:
        raise RuntimeError(f"Could not reach CoinGecko for {asset}.") from exc

    series: dict[date, float] = {}
    for timestamp_ms, price in payload["prices"]:
        day = datetime.fromtimestamp(timestamp_ms / 1000, tz=UTC).date()
        if GLOBAL_START_DATE <= day <= GLOBAL_END_DATE:
            series[day] = float(price)
    return series


def fetch_price_series_from_yahoo(asset: str) -> dict[date, float]:
    symbol = YAHOO_SYMBOLS[asset]
    start_ts = int(datetime(GLOBAL_START_DATE.year, GLOBAL_START_DATE.month, GLOBAL_START_DATE.day, tzinfo=UTC).timestamp())
    end_ts = int(datetime(GLOBAL_END_DATE.year, GLOBAL_END_DATE.month, GLOBAL_END_DATE.day, tzinfo=UTC).timestamp()) + 86_400
    request = Request(
        YAHOO_CHART_URL.format(symbol=symbol, period1=start_ts, period2=end_ts),
        headers={
            "accept": "application/json",
            "user-agent": "demeter-rebalancing-study/2.0",
        },
    )
    try:
        with urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        raise RuntimeError(f"Yahoo Finance request failed for {asset}: HTTP {exc.code}") from exc
    except URLError as exc:
        raise RuntimeError(f"Could not reach Yahoo Finance for {asset}.") from exc

    chart = payload.get("chart", {})
    if chart.get("error") is not None:
        raise RuntimeError(f"Yahoo Finance returned an error for {asset}: {chart['error']}")

    result = chart["result"][0]
    timestamps = result["timestamp"]
    closes = result["indicators"]["quote"][0]["close"]
    series: dict[date, float] = {}
    for timestamp, close in zip(timestamps, closes, strict=True):
        if close is None:
            continue
        day = datetime.fromtimestamp(timestamp, tz=UTC).date()
        if GLOBAL_START_DATE <= day <= GLOBAL_END_DATE:
            series[day] = float(close)
    return series


def fetch_and_cache_asset(asset: str) -> tuple[Path, dict[date, float]]:
    cache_path = asset_cache_path(asset)
    try:
        series = fetch_price_series_from_coingecko(asset)
    except RuntimeError:
        series = fetch_price_series_from_yahoo(asset)
    write_asset_cache(cache_path, series.items())
    time.sleep(1.0)
    return cache_path, series


def load_or_fetch_asset(asset: str) -> tuple[Path, dict[date, float]]:
    cache_path = asset_cache_path(asset)
    if cache_path.exists():
        return cache_path, load_asset_cache(cache_path)
    return fetch_and_cache_asset(asset)


def load_or_fetch_prices(
    assets: tuple[str, ...],
    start_date: date,
    end_date: date,
) -> tuple[dict[str, Path], list[MarketPoint]]:
    cache_paths: dict[str, Path] = {}
    series_by_asset: dict[str, dict[date, float]] = {}

    for asset in assets:
        cache_path, series = load_or_fetch_asset(asset)
        cache_paths[asset] = cache_path
        series_by_asset[asset] = series

    common_days = set.intersection(*(set(series.keys()) for series in series_by_asset.values()))
    valid_days = sorted(day for day in common_days if start_date <= day <= end_date)
    if not valid_days:
        raise RuntimeError(
            f"No overlapping price history found for assets {assets} in {start_date.isoformat()} to {end_date.isoformat()}."
        )

    points = [
        MarketPoint(day=day, prices={asset: series_by_asset[asset][day] for asset in assets})
        for day in valid_days
    ]
    return cache_paths, points
