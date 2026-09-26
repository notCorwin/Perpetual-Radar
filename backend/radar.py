"""OKX data collector and HTTP API for the radar."""

import asyncio
import json
import logging
import math
import os
import sqlite3
import statistics
import time
from contextlib import suppress
from pathlib import Path
from urllib.parse import urlencode

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web

API = "https://www.okx.com/api/v5"
PUBLIC_WS = "wss://ws.okx.com:8443/ws/v5/public"
BUSINESS_WS = "wss://ws.okx.com:8443/ws/v5/business"
HOUR = 3_600_000
PERIODS = 48
MAX_INDICATOR_PERIOD = 100
EMA_PERIOD = 200
VWAP_PERIOD = 14
BOLL_PERIOD = 20
CANDLE_LOOKBACK = max(MAX_INDICATOR_PERIOD * 2, EMA_PERIOD)
LOG = logging.getLogger(__name__)


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def log_change(current, previous):
    return math.log(current / previous) if current is not None and previous is not None and current > 0 and previous > 0 else None


def extremes(candles, hour):
    high = low = None
    for age in range(1, PERIODS + 1):
        bar = candles.get(hour - age * HOUR)
        if not bar or not bar[4]:
            return None, None
        if high is None or bar[1] > high:
            high = bar[1]
        if low is None or bar[2] < low:
            low = bar[2]
    return high, low


def roc_maroc(candles, hour, roc_period, maroc_period):
    def roc_at(offset):
        current = candles.get(hour - offset * HOUR)
        previous = candles.get(hour - (offset + roc_period) * HOUR)
        if not current or not previous or (offset and not current[4]) or not previous[4] or previous[3] <= 0:
            return None
        return (current[3] / previous[3] - 1) * 100

    values = [roc_at(offset) for offset in range(maroc_period)]
    return values[0], sum(values) / maroc_period if all(value is not None for value in values) else None


def vwap(candles, hour):
    if hour not in candles:
        return None
    base = quote = 0
    for ts in range(hour - (VWAP_PERIOD - 1) * HOUR, hour + HOUR, HOUR):
        bar = candles.get(ts)
        if not bar or (ts < hour and not bar[4]) or len(bar) < 7 or bar[6] is None:
            return None
        quote += bar[5]
        base += bar[6]
    return quote / base if base > 0 else None


def rsi(candles, hour, period):
    closes = []
    for age in range(CANDLE_LOOKBACK + 1):
        bar = candles.get(hour - age * HOUR)
        if not bar or (age and not bar[4]):
            break
        closes.append(bar[3])
    if len(closes) <= period:
        return None
    closes.reverse()
    changes = [current - previous for previous, current in zip(closes, closes[1:])]
    gain = sum(max(change, 0) for change in changes[:period]) / period
    loss = sum(max(-change, 0) for change in changes[:period]) / period
    for change in changes[period:]:
        gain = (gain * (period - 1) + max(change, 0)) / period
        loss = (loss * (period - 1) + max(-change, 0)) / period
    return 100 * gain / (gain + loss) if gain + loss else 50


def boll(candles, hour):
    closes = []
    for age in range(BOLL_PERIOD):
        bar = candles.get(hour - age * HOUR)
        if not bar or (age and not bar[4]):
            return None, None, None
        closes.append(bar[3])
    middle = statistics.fmean(closes)
    width = 2 * statistics.pstdev(closes, middle)
    return middle + width, middle, middle - width


def percent_change(current, previous):
    return (current - previous) / abs(previous) * 100 if current is not None and previous is not None and previous != 0 else None


def indicator_period(query, name):
    try:
        value = int(query.get(name, "9"))
    except ValueError:
        raise web.HTTPBadRequest(text=f"{name} must be an integer from 1 to {MAX_INDICATOR_PERIOD}") from None
    if not 1 <= value <= MAX_INDICATOR_PERIOD:
        raise web.HTTPBadRequest(text=f"{name} must be an integer from 1 to {MAX_INDICATOR_PERIOD}")
    return value


def parse_candle(values):
    if not isinstance(values, list) or len(values) < 9 or values[8] not in ("0", "1"):
        return None
    ts = number(values[0])
    high, low, close, base_volume, quote_volume = (number(values[i]) for i in (2, 3, 4, 6, 7))
    if (ts is None or ts % HOUR or any(x is None for x in (high, low, close, base_volume, quote_volume))
            or low <= 0 or high < low or not low <= close <= high or base_volume < 0 or quote_volume < 0):
        return None
    return int(ts), (int(ts), high, low, close, values[8] == "1", quote_volume, base_volume)


def oi_base(history, hour):
    """The previous completed hour's final OI is this hour's baseline."""
    for item in history:
        if isinstance(item, list) and len(item) >= 2 and number(item[0]) == hour - HOUR:
            value = number(item[1])
            return value if value is not None and value > 0 else None
    return None


def taker_values(history, hour):
    """OKX returns [hour, sell volume, buy volume] in contract units."""
    for item in history:
        if isinstance(item, list) and len(item) >= 3 and number(item[0]) == hour:
            sell, buy = number(item[1]), number(item[2])
            if sell is not None and buy is not None and sell >= 0 and buy >= 0:
                return buy, sell
    return None


class Radar:
    def __init__(self, cache_path=None):
        self.session = None
        self.db = None
        self.cache_path = cache_path or os.getenv("CACHE_PATH", "radar.sqlite3")
        self.rows = {}
        self.candles = {}
        self.ema_states = {}
        self.hour = int(time.time() * 1000) // HOUR * HOUR
        self.updated_at = None
        self.failed_paths = set()
        self.disconnected_channels = set()
        self.tasks = []
        self.origins = set(filter(None, os.getenv("ALLOWED_ORIGINS", "http://127.0.0.1:5173,http://localhost:5173").split(",")))

    async def get(self, path, **params):
        url = f"{API}{path}?{urlencode(params)}"
        async with self.session.get(url) as response:
            response.raise_for_status()
            body = await response.json()
        if body.get("code") != "0" or not isinstance(body.get("data"), list):
            raise ValueError(body.get("msg") or f"OKX {body.get('code')}")
        return body["data"]

    def touch(self):
        self.updated_at = int(time.time() * 1000)

    def open_cache(self):
        Path(self.cache_path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.cache_path)
        self.db.execute("CREATE TABLE IF NOT EXISTS oi_base (inst_id TEXT, hour INTEGER, value REAL, PRIMARY KEY (inst_id, hour))")
        self.db.execute("CREATE TABLE IF NOT EXISTS candles (inst_id TEXT, hour INTEGER, high REAL, low REAL, close REAL, volume REAL, base_volume REAL, PRIMARY KEY (inst_id, hour))")
        if "base_volume" not in {column[1] for column in self.db.execute("PRAGMA table_info(candles)")}:
            self.db.execute("ALTER TABLE candles ADD COLUMN base_volume REAL")
        self.db.execute("CREATE TABLE IF NOT EXISTS ema200 (inst_id TEXT PRIMARY KEY, hour INTEGER, value REAL)")
        self.prune_cache()

    def prune_cache(self):
        cutoff = self.hour - CANDLE_LOOKBACK * HOUR
        self.db.execute("DELETE FROM oi_base WHERE hour != ?", (self.hour,))
        self.db.execute("DELETE FROM candles WHERE hour < ?", (cutoff,))
        self.db.execute("DELETE FROM ema200 WHERE hour < ? OR hour >= ?", (cutoff - HOUR, self.hour))
        if self.rows:
            stale = [(inst_id,) for (inst_id,) in self.db.execute("SELECT inst_id FROM ema200") if inst_id not in self.rows]
            self.db.executemany("DELETE FROM ema200 WHERE inst_id = ?", stale)
        self.db.commit()
        for inst_id, series in list(self.candles.items()):
            fresh = {ts: bar for ts, bar in series.items() if ts >= cutoff}
            if fresh:
                self.candles[inst_id] = fresh
            else:
                del self.candles[inst_id]
        self.ema_states = {inst_id: state for inst_id, state in self.ema_states.items()
                           if cutoff - HOUR <= state[0] < self.hour and (not self.rows or inst_id in self.rows)}

    def load_cache(self):
        for inst_id, _, value in self.db.execute("SELECT inst_id, hour, value FROM oi_base WHERE hour = ?", (self.hour,)):
            row = self.rows.get(inst_id)
            if row:
                row["oiBase"] = value
                row["oiLog"] = log_change(row["oi"], value)
        for inst_id, ts, high, low, close, volume, base_volume in self.db.execute("SELECT inst_id, hour, high, low, close, volume, base_volume FROM candles WHERE hour >= ? AND hour < ?", (self.hour - CANDLE_LOOKBACK * HOUR, self.hour)):
            if inst_id in self.rows:
                self.candles.setdefault(inst_id, {})[ts] = (ts, high, low, close, True, volume, base_volume)
        self.ema_states = {inst_id: (ts, value) for inst_id, ts, value in self.db.execute("SELECT inst_id, hour, value FROM ema200") if inst_id in self.rows}
        self.touch()

    def has_candle_history(self, inst_id):
        series = self.candles.get(inst_id, {})
        history_ready = all(series.get(self.hour - n * HOUR, (None, None, None, None, False))[4] for n in range(1, CANDLE_LOOKBACK + 1))
        vwap_ready = all(len(series.get(self.hour - n * HOUR, ())) >= 7 and series[self.hour - n * HOUR][6] is not None for n in range(1, VWAP_PERIOD))
        return history_ready and vwap_ready

    def completed_ema200(self, inst_id, series):
        target = self.hour - HOUR
        state = self.ema_states.get(inst_id)
        if state and state[0] < target:
            for ts in range(state[0] + HOUR, target + HOUR, HOUR):
                bar = series.get(ts)
                if not bar or not bar[4]:
                    state = None
                    break
                state = (ts, state[1] + (bar[3] - state[1]) * 2 / (EMA_PERIOD + 1))
        if not state or state[0] != target:
            bars = [series.get(target - n * HOUR) for n in range(EMA_PERIOD)]
            if any(not bar or not bar[4] for bar in bars):
                return None
            state = (target, sum(bar[3] for bar in bars) / EMA_PERIOD)
        if self.ema_states.get(inst_id) != state:
            self.ema_states[inst_id] = state
            if self.db:
                self.db.execute("INSERT OR REPLACE INTO ema200 VALUES (?, ?, ?)", (inst_id, *state))
                self.db.commit()
        return state[1]

    def update_candle(self, inst_id, values, history=False):
        parsed = parse_candle(values)
        if inst_id not in self.rows or not parsed or parsed[0] < self.hour - CANDLE_LOOKBACK * HOUR:
            return
        ts, candle = parsed
        series = self.candles.setdefault(inst_id, {})
        old = series.get(ts)
        if not history or old is None or (not old[4] and candle[4]) or (old[4] and (len(old) < 7 or old[6] is None)):
            if history and old and old[4] and (len(old) < 7 or old[6] is None):
                candle = (*old[:6], candle[6])
            series[ts] = candle
            if candle[4] and self.db:
                self.db.execute("INSERT INTO candles (inst_id, hour, high, low, close, volume, base_volume) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(inst_id, hour) DO UPDATE SET base_volume = COALESCE(candles.base_volume, excluded.base_volume)", (inst_id, ts, candle[1], candle[2], candle[3], candle[5], candle[6]))
                if not history:
                    self.db.commit()
        for previous_ts in list(series):
            if previous_ts < self.hour - CANDLE_LOOKBACK * HOUR:
                del series[previous_ts]
        row = self.rows[inst_id]
        current = series.get(self.hour)
        previous = series.get(self.hour - HOUR)
        row["takerLog"] = log_change(current[5] if current else None, previous[5] if previous and previous[4] else None)
        self.touch()

    def update_oi(self, item):
        row = self.rows.get(item.get("instId"))
        current, stamp = number(item.get("oi")), number(item.get("ts"))
        if row is None or current is None or current < 0 or stamp is None or stamp < row["oiTs"]:
            return
        row["oi"] = current
        row["oiTs"] = stamp
        row["oiUsd"] = number(item.get("oiUsd"))
        row["oiLog"] = log_change(current, row["oiBase"])
        self.touch()

    async def instruments(self):
        items, interest = await asyncio.gather(
            self.get("/public/instruments", instType="SWAP"),
            self.get("/public/open-interest", instType="SWAP"),
        )
        selected = [item for item in items if item.get("state") == "live" and item.get("instCategory") == "1"
                    and item.get("settleCcy") == "USDT" and item.get("instId", "").endswith("-USDT-SWAP")
                    and item.get("instId") != "USDC-USDT-SWAP"]
        if not selected:
            raise ValueError("No live USDT perpetual swaps found")
        self.rows = {item["instId"]: {
            "instId": item["instId"], "oi": None, "oiTs": 0, "oiBase": None,
            "oiLog": None, "oiUsd": None, "buy": None, "sell": None,
            "takerRatio": None, "takerLog": None,
        } for item in selected}
        for item in interest:
            self.update_oi(item)
        self.touch()

    async def scan(self, path, delay, callback, repeat=False):
        ids = list(self.rows)
        if path == "/rubik/stat/contracts/open-interest-history":
            ids = [inst_id for inst_id in ids if self.rows[inst_id]["oiBase"] is None]
        while True:
            failed = set()
            pending = set()
            try:
                for inst_id in ids:
                    task = asyncio.create_task(self.fetch_one(path, inst_id, callback, failed))
                    pending.add(task)
                    task.add_done_callback(pending.discard)
                    if len(pending) >= 10:
                        await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
                    await asyncio.sleep(delay)
                if pending:
                    await asyncio.gather(*pending)
            finally:
                for task in pending:
                    task.cancel()
                if pending:
                    await asyncio.gather(*pending, return_exceptions=True)
            if path == "/rubik/stat/contracts/open-interest-history":
                failed.update(inst_id for inst_id in ids if self.rows[inst_id]["oiBase"] is None)
            if not failed:
                self.failed_paths.discard(path)
            if not repeat and not failed:
                return
            ids = list(self.rows) if repeat else list(failed)
            await asyncio.sleep(10)

    async def fetch_one(self, path, inst_id, callback, failed):
        try:
            values = await self.get(path, instId=inst_id, **({"bar": "1H", "limit": 1 if self.has_candle_history(inst_id) else CANDLE_LOOKBACK + 1} if path == "/market/candles" else {"period": "1H"}))
            callback(inst_id, values)
        except Exception as exc:
            failed.add(inst_id)
            LOG.warning("%s %s: %s", path, inst_id, exc)
            self.failed_paths.add(path)

    def load_history(self, inst_id, values):
        row = self.rows.get(inst_id)
        if row:
            row["oiBase"] = oi_base(values, self.hour)
            row["oiLog"] = log_change(row["oi"], row["oiBase"])
            if row["oiBase"] is not None and self.db:
                self.db.execute("INSERT OR IGNORE INTO oi_base VALUES (?, ?, ?)", (inst_id, self.hour, row["oiBase"]))
                self.db.commit()
            self.touch()

    def load_taker(self, inst_id, values):
        row = self.rows.get(inst_id)
        pair = taker_values(values, self.hour)
        if row and pair:
            buy, sell = pair
            row["buy"], row["sell"] = buy, sell
            row["takerRatio"] = (buy - sell) / (buy + sell) * 100 if buy + sell else None
            self.touch()

    def load_candles(self, inst_id, values):
        for bar in values:
            self.update_candle(inst_id, bar, history=True)
        if self.db:
            self.db.commit()

    async def ws_loop(self, url, channel, handler):
        wait = 1
        while True:
            try:
                async with self.session.ws_connect(url, heartbeat=20) as ws:
                    args = [{"channel": channel, "instId": inst_id} for inst_id in self.rows]
                    for index in range(0, len(args), 50):
                        await ws.send_json({"op": "subscribe", "args": args[index:index + 50]})
                        await asyncio.sleep(0.1)
                    self.disconnected_channels.discard(channel)
                    wait = 1
                    async for message in ws:
                        if message.type == WSMsgType.TEXT and message.data == "pong":
                            continue
                        if message.type != WSMsgType.TEXT:
                            continue
                        payload = json.loads(message.data)
                        if payload.get("event") == "error":
                            raise ValueError(payload.get("msg", "Subscription failed"))
                        if payload.get("arg", {}).get("channel") == channel:
                            for item in payload.get("data", []):
                                handler(payload["arg"].get("instId"), item)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                LOG.warning("%s WebSocket: %s", channel, exc)
                self.disconnected_channels.add(channel)
            await asyncio.sleep(wait)
            wait = min(wait * 2, 30)

    def ws_oi(self, _inst_id, item):
        if isinstance(item, dict):
            self.update_oi(item)

    def ws_candle(self, inst_id, item):
        self.update_candle(inst_id, item)

    async def clock_loop(self):
        while True:
            await asyncio.sleep(1)
            hour = int(time.time() * 1000) // HOUR * HOUR
            if hour != self.hour:
                self.hour = hour
                self.prune_cache()
                for row in self.rows.values():
                    row.update(oiBase=None, oiLog=None, buy=None, sell=None, takerRatio=None, takerLog=None)
                self.touch()
                self.tasks = [task for task in self.tasks if not task.done()]
                self.tasks.extend((
                    asyncio.create_task(self.scan("/market/candles", 0.12, self.load_candles)),
                    asyncio.create_task(self.scan("/rubik/stat/contracts/open-interest-history", 0.25, self.load_history)),
                ))

    async def start(self):
        self.open_cache()
        self.session = ClientSession(timeout=ClientTimeout(total=15))
        await self.instruments()
        self.prune_cache()
        self.load_cache()
        self.tasks = [
            asyncio.create_task(self.scan("/market/candles", 0.12, self.load_candles)),
            asyncio.create_task(self.scan("/rubik/stat/contracts/open-interest-history", 0.25, self.load_history)),
            asyncio.create_task(self.scan("/rubik/stat/taker-volume-contract", 0.25, self.load_taker, repeat=True)),
            asyncio.create_task(self.ws_loop(PUBLIC_WS, "open-interest", self.ws_oi)),
            asyncio.create_task(self.ws_loop(BUSINESS_WS, "candle1H", self.ws_candle)),
            asyncio.create_task(self.clock_loop()),
        ]

    async def stop(self):
        for task in self.tasks:
            task.cancel()
        for task in self.tasks:
            with suppress(asyncio.CancelledError):
                await task
        if self.session:
            await self.session.close()
        if self.db:
            self.db.close()

    async def response(self, request):
        origin = request.headers.get("Origin")
        if origin and origin not in self.origins:
            raise web.HTTPForbidden()
        roc_period = indicator_period(request.query, "rocPeriod")
        maroc_period = indicator_period(request.query, "marocPeriod")
        headers = {"Cache-Control": "no-store"}
        if origin:
            headers["Access-Control-Allow-Origin"] = origin
            headers["Vary"] = "Origin"
        rows = []
        for inst_id, row in self.rows.items():
            series = self.candles.get(inst_id, {})
            high, low = extremes(series, self.hour)
            boll_upper, boll_middle, boll_lower = boll(series, self.hour)
            roc, maroc = roc_maroc(series, self.hour, roc_period, maroc_period)
            current = series.get(self.hour)
            previous = series.get(self.hour - HOUR)
            previous_roc, previous_maroc = roc_maroc(series, self.hour - HOUR, roc_period, maroc_period) if previous and previous[4] else (None, None)
            price = current[3] if current else None
            previous_ema = self.completed_ema200(inst_id, series)
            current_ema = previous_ema + (price - previous_ema) * 2 / (EMA_PERIOD + 1) if previous_ema is not None and price is not None else None
            rows.append(row | {
                "price": price,
                "priceChange": percent_change(price, previous[3] if previous and previous[4] else None),
                "vwap14": vwap(series, self.hour),
                "ema200": current_ema,
                "ema200Slope": current_ema - previous_ema if current_ema is not None else None,
                "high48": high, "high48Diff": percent_change(price, high),
                "low48": low, "low48Diff": percent_change(price, low),
                "roc": roc, "maroc": maroc,
                "rocChange": percent_change(roc, previous_roc),
                "marocChange": percent_change(maroc, previous_maroc),
                "rsi6": rsi(series, self.hour, 6),
                "rsi12": rsi(series, self.hour, 12),
                "rsi24": rsi(series, self.hour, 24),
                "bollUpper": boll_upper,
                "bollMiddle": boll_middle,
                "bollLower": boll_lower,
            })
        error = ""
        if self.failed_paths:
            error = "Some OKX data is unavailable; retrying."
        elif self.disconnected_channels:
            error = f"OKX {min(self.disconnected_channels)} disconnected; reconnecting."
        return web.json_response({"rows": rows, "updatedAt": self.updated_at, "error": error}, headers=headers)


async def app_context(app):
    radar = Radar()
    app["radar"] = radar
    await radar.start()
    yield
    await radar.stop()


def main():
    logging.basicConfig(level=logging.INFO)
    app = web.Application()
    app.cleanup_ctx.append(app_context)
    app.router.add_get("/api/rows", lambda request: request.app["radar"].response(request))
    web.run_app(app, host=os.getenv("HOST", "127.0.0.1"), port=int(os.getenv("PORT", "8765")), access_log=None)


if __name__ == "__main__":
    main()
