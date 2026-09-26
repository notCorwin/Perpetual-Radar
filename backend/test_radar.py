import math
import asyncio
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from aiohttp import web
from aiohttp.test_utils import make_mocked_request

from backend.radar import CANDLE_LOOKBACK, HOUR, Radar, boll, extremes, indicator_period, log_change, oi_base, parse_candle, percent_change, roc_maroc, rsi, taker_values


class RadarTest(unittest.TestCase):
    def test_recovered_scan_clears_only_its_own_error(self):
        radar = Radar()
        inst_id = "BTC-USDT-SWAP"
        path = "/rubik/stat/taker-volume-contract"
        radar.rows[inst_id] = {"instId": inst_id}
        failing = True

        async def get(_path, **_params):
            if failing:
                raise ValueError("temporary failure")
            return []

        radar.get = get

        async def check():
            nonlocal failing
            await radar.fetch_one(path, inst_id, lambda *_: None, set())
            self.assertIn(path, radar.failed_paths)
            failing = False
            await radar.scan("/market/candles", 0, lambda *_: None)
            self.assertIn(path, radar.failed_paths)
            await radar.scan(path, 0, lambda *_: None)
            self.assertNotIn(path, radar.failed_paths)
            response = await radar.response(make_mocked_request("GET", "/api/rows"))
            self.assertEqual(json.loads(response.text)["error"], "")

        asyncio.run(check())

    def test_symbol_price_compares_current_with_previous_completed_hour(self):
        radar = Radar()
        radar.hour = 50 * HOUR
        radar.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP"}
        radar.candles["BTC-USDT-SWAP"] = {
            radar.hour: (radar.hour, 110, 100, 105, False, 10),
            radar.hour - HOUR: (radar.hour - HOUR, 105, 95, 100, True, 10),
        }
        request = make_mocked_request("GET", "/api/rows")
        row = json.loads(asyncio.run(radar.response(request)).text)["rows"][0]
        self.assertEqual((row["price"], row["priceChange"]), (105, 5))
        radar.candles["BTC-USDT-SWAP"][radar.hour - HOUR] = (radar.hour - HOUR, 105, 95, 100, False, 10)
        row = json.loads(asyncio.run(radar.response(request)).text)["rows"][0]
        self.assertIsNone(row["priceChange"])

    def test_roc_and_maroc_use_hourly_closes(self):
        hour = 20 * HOUR
        candles = {n * HOUR: (n * HOUR, 110 + n, 90 + n, 100 + n, n < 20, 100) for n in range(21)}
        roc, maroc = roc_maroc(candles, hour, 2, 3)
        self.assertAlmostEqual(roc, (120 / 118 - 1) * 100)
        self.assertAlmostEqual(maroc, sum((close / (close - 2) - 1) * 100 for close in (120, 119, 118)) / 3)
        del candles[16 * HOUR]
        self.assertAlmostEqual(roc_maroc(candles, hour, 2, 3)[0], roc)
        self.assertIsNone(roc_maroc(candles, hour, 2, 3)[1])
        max_hour = CANDLE_LOOKBACK * HOUR
        full = {n * HOUR: (n * HOUR, 110, 90, 100, n < CANDLE_LOOKBACK, 100) for n in range(CANDLE_LOOKBACK + 1)}
        self.assertEqual(roc_maroc(full, max_hour, 100, 100), (0, 0))
        self.assertEqual(roc_maroc(full, max_hour - HOUR, 100, 100), (0, 0))
        self.assertEqual(percent_change(8.39, 8.14), (8.39 - 8.14) / 8.14 * 100)
        self.assertEqual(percent_change(-7.32, -7.28), (-7.32 + 7.28) / 7.28 * 100)
        self.assertIsNone(percent_change(8.39, 0))

    def test_rsi_uses_wilder_smoothing_and_requires_contiguous_closes(self):
        closes = [100, 102, 101, 104, 102, 103, 105, 104]
        series = {index * HOUR: (index * HOUR, close + 1, close - 1, close, index < 7, 1) for index, close in enumerate(closes)}
        gain = (8 / 6) * 5 / 6
        loss = ((3 / 6) * 5 + 1) / 6
        self.assertAlmostEqual(rsi(series, 7 * HOUR, 6), 100 * gain / (gain + loss))
        self.assertIsNone(rsi(series, 7 * HOUR, 12))

        hour = 30 * HOUR
        for step, expected in ((1, 100), (0, 50), (-1, 0)):
            bars = {index * HOUR: (index * HOUR, 140, 60, 100 + index * step, index < 30, 1) for index in range(31)}
            radar = Radar()
            radar.hour = hour
            radar.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP"}
            radar.candles["BTC-USDT-SWAP"] = bars
            row = json.loads(asyncio.run(radar.response(make_mocked_request("GET", "/api/rows"))).text)["rows"][0]
            self.assertEqual((row["rsi6"], row["rsi12"], row["rsi24"]), (expected, expected, expected))
        del bars[hour - HOUR]
        self.assertIsNone(rsi(bars, hour, 6))

    def test_boll_uses_20_hourly_closes_and_two_population_deviations(self):
        hour = 19 * HOUR
        bars = {index * HOUR: (index * HOUR, 121, 99, 100 + index, index < 19, 1) for index in range(20)}
        middle = 109.5
        width = 2 * math.sqrt((20 ** 2 - 1) / 12)
        upper, actual_middle, lower = boll(bars, hour)
        self.assertAlmostEqual(upper, middle + width)
        self.assertAlmostEqual(actual_middle, middle)
        self.assertAlmostEqual(lower, middle - width)
        radar = Radar()
        radar.hour = hour
        radar.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP"}
        radar.candles["BTC-USDT-SWAP"] = bars
        row = json.loads(asyncio.run(radar.response(make_mocked_request("GET", "/api/rows"))).text)["rows"][0]
        self.assertAlmostEqual(row["bollUpper"], upper)
        self.assertAlmostEqual(row["bollMiddle"], middle)
        self.assertAlmostEqual(row["bollLower"], lower)
        bars[hour - HOUR] = (hour - HOUR, 121, 99, 118, False, 1)
        self.assertEqual(boll(bars, hour), (None, None, None))

    def test_indicator_period_bounds(self):
        self.assertEqual(indicator_period({}, "rocPeriod"), 9)
        for value in ("0", "101", "abc"):
            with self.assertRaises(web.HTTPBadRequest):
                indicator_period({"rocPeriod": value}, "rocPeriod")

    def test_instruments_exclude_usdc(self):
        radar = Radar()

        async def get(path, **_params):
            if path == "/public/instruments":
                return [
                    {"instId": inst_id, "state": "live", "instCategory": "1", "settleCcy": "USDT"}
                    for inst_id in ("BTC-USDT-SWAP", "USDC-USDT-SWAP")
                ]
            return []

        radar.get = get
        asyncio.run(radar.instruments())
        self.assertEqual(list(radar.rows), ["BTC-USDT-SWAP"])

    def test_hourly_history_and_formulas(self):
        hour = 50 * HOUR
        self.assertEqual(oi_base([[str(hour), "100"], [str(hour - HOUR), "90"]], hour), 90)
        self.assertIsNone(oi_base([[str(hour), "100"]], hour))
        self.assertEqual(taker_values([[str(hour), "30", "70"]], hour), (70, 30))
        self.assertEqual(log_change(110, 100), math.log(1.1))
        self.assertIsNone(log_change(0, 100))

    def test_extremes_use_48_complete_prior_hours(self):
        hour = 50 * HOUR
        candles = {hour - n * HOUR: (hour - n * HOUR, 110, 90, 100, True, 100) for n in range(1, 49)}
        candles[hour] = (hour, 200, 50, 140, False, 200)
        candles[hour - 7 * HOUR] = (hour - 7 * HOUR, 125, 90, 100, True, 100)
        candles[hour - 9 * HOUR] = (hour - 9 * HOUR, 125, 90, 100, True, 100)
        candles[hour - 27 * HOUR] = (hour - 27 * HOUR, 110, 80, 100, True, 100)
        self.assertEqual(extremes(candles, hour), (125, 80))
        candles[hour - 48 * HOUR] = (hour - 48 * HOUR, 130, 70, 100, True, 100)
        self.assertEqual(extremes(candles, hour), (130, 70))
        radar = Radar()
        radar.hour = hour
        radar.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP"}
        radar.candles["BTC-USDT-SWAP"] = candles
        row = json.loads(asyncio.run(radar.response(make_mocked_request("GET", "/api/rows"))).text)["rows"][0]
        self.assertAlmostEqual(row["high48Diff"], (140 / 130 - 1) * 100)
        self.assertAlmostEqual(row["low48Diff"], (140 / 70 - 1) * 100)
        self.assertEqual(parse_candle([str(hour), "100", "112", "100", "111", "0", "0", "200", "0"])[0], hour)
        candles[hour - HOUR] = (hour - HOUR, 110, 90, 100, False, 100)
        self.assertEqual(extremes(candles, hour), (None, None))

    def test_oi_current_update_uses_historical_hour_base(self):
        radar = Radar()
        radar.hour = 50 * HOUR
        radar.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP", "oi": None, "oiTs": 0, "oiBase": None, "oiLog": None, "oiUsd": None}
        radar.load_history("BTC-USDT-SWAP", [[str(radar.hour - HOUR), "100"]])
        radar.update_oi({"instId": "BTC-USDT-SWAP", "oi": "110", "oiUsd": "1000", "ts": str(radar.hour + 1000)})
        self.assertAlmostEqual(radar.rows["BTC-USDT-SWAP"]["oiLog"], math.log(1.1))
        radar.update_oi({"instId": "BTC-USDT-SWAP", "oi": "90", "ts": str(radar.hour + 500)})
        self.assertEqual(radar.rows["BTC-USDT-SWAP"]["oi"], 110)

    def test_completed_data_survives_restart_and_skips_oi_fetch(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "radar.sqlite3")
            hour = 250 * HOUR
            first = Radar(path)
            first.hour = hour
            first.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP", "oi": 110, "oiTs": 0, "oiBase": None, "oiLog": None, "takerLog": None}
            first.open_cache()
            first.load_history("BTC-USDT-SWAP", [[str(hour - HOUR), "100"]])
            first.load_candles("BTC-USDT-SWAP", [
                [str(hour - n * HOUR), "100", "110", "90", "100", "0", "0", "100", "1"]
                for n in range(1, CANDLE_LOOKBACK + 1)
            ])
            first.db.close()

            second = Radar(path)
            second.hour = hour
            second.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP", "oi": 120, "oiBase": None, "oiLog": None}
            second.open_cache()
            second.load_cache()
            self.assertEqual(second.rows["BTC-USDT-SWAP"]["oiBase"], 100)
            self.assertAlmostEqual(second.rows["BTC-USDT-SWAP"]["oiLog"], math.log(1.2))
            self.assertTrue(second.has_candle_history("BTC-USDT-SWAP"))
            asyncio.run(second.scan("/rubik/stat/contracts/open-interest-history", 0, second.load_history))
            second.db.close()

    def test_vwap14_and_ema200_survive_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "radar.sqlite3")
            hour = 200 * HOUR
            first = Radar(path)
            first.hour = hour
            first.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP"}
            first.open_cache()

            def candle(ts, close, base, confirmed):
                return [str(ts), str(close), str(close + 1), str(close - 1), str(close), "1", str(base), str(close * base), "1" if confirmed else "0"]

            first.load_candles("BTC-USDT-SWAP", [candle(hour - n * HOUR, 300 - n, 1, True) for n in range(1, 201)] + [candle(hour, 300, 2, False)])
            request = make_mocked_request("GET", "/api/rows")
            row = json.loads(asyncio.run(first.response(request)).text)["rows"][0]
            prior_ema = sum(range(100, 300)) / 200
            current_ema = prior_ema + (300 - prior_ema) * 2 / 201
            self.assertAlmostEqual(row["vwap14"], (sum(range(287, 300)) + 600) / 15)
            self.assertAlmostEqual(row["ema200"], current_ema)
            self.assertGreater(row["ema200Slope"], 0)

            first.hour += HOUR
            first.update_candle("BTC-USDT-SWAP", candle(hour, 300, 2, True))
            first.update_candle("BTC-USDT-SWAP", candle(first.hour, 50, 1, False))
            row = json.loads(asyncio.run(first.response(request)).text)["rows"][0]
            falling_ema = current_ema + (50 - current_ema) * 2 / 201
            self.assertAlmostEqual(row["ema200"], falling_ema)
            self.assertLess(row["ema200Slope"], 0)
            first.db.close()

            second = Radar(path)
            second.hour = first.hour
            second.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP"}
            second.open_cache()
            second.load_cache()
            second.update_candle("BTC-USDT-SWAP", candle(second.hour, 50, 1, False))
            row = json.loads(asyncio.run(second.response(request)).text)["rows"][0]
            self.assertAlmostEqual(row["ema200"], falling_ema)
            self.assertIsNotNone(row["vwap14"])
            second.db.close()

    def test_existing_candle_cache_adds_vwap_volume(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "radar.sqlite3")
            hour = 200 * HOUR
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE candles (inst_id TEXT, hour INTEGER, high REAL, low REAL, close REAL, volume REAL, PRIMARY KEY (inst_id, hour))")
                db.execute("INSERT INTO candles VALUES (?, ?, ?, ?, ?, ?)", ("BTC-USDT-SWAP", hour - HOUR, 101, 99, 100, 100))
            db.close()
            radar = Radar(path)
            radar.hour = hour
            radar.rows["BTC-USDT-SWAP"] = {"instId": "BTC-USDT-SWAP"}
            radar.open_cache()
            radar.load_cache()
            self.assertIsNone(radar.candles["BTC-USDT-SWAP"][hour - HOUR][6])
            radar.load_candles("BTC-USDT-SWAP", [[str(hour - HOUR), "101", "102", "100", "101", "1", "2", "202", "1"]])
            self.assertEqual(radar.candles["BTC-USDT-SWAP"][hour - HOUR][6], 2)
            self.assertEqual(radar.candles["BTC-USDT-SWAP"][hour - HOUR][3], 100)
            self.assertEqual(radar.db.execute("SELECT close, base_volume FROM candles").fetchone(), (100, 2))
            radar.db.close()

    def test_expired_cache_is_pruned_on_start_and_hour_change(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "radar.sqlite3")
            radar = Radar(path)
            radar.hour = 250 * HOUR
            radar.rows["BTC-USDT-SWAP"] = {"oiBase": 1, "oiLog": 1, "buy": 1, "sell": 1, "takerRatio": 1, "takerLog": 1}
            radar.open_cache()
            cutoff = radar.hour - CANDLE_LOOKBACK * HOUR
            radar.db.executemany("INSERT INTO candles VALUES (?, ?, 110, 90, 100, 100, 1)",
                                 [("BTC-USDT-SWAP", cutoff - HOUR), ("BTC-USDT-SWAP", cutoff), ("BTC-USDT-SWAP", radar.hour - HOUR)])
            radar.db.executemany("INSERT INTO oi_base VALUES (?, ?, 100)",
                                 [("BTC-USDT-SWAP", radar.hour - HOUR), ("BTC-USDT-SWAP", radar.hour)])
            radar.db.executemany("INSERT INTO ema200 VALUES (?, ?, 100)",
                                 [("OLD-USDT-SWAP", radar.hour - HOUR), ("BTC-USDT-SWAP", cutoff - HOUR)])
            radar.candles["BTC-USDT-SWAP"] = {ts: (ts, 110, 90, 100, True, 100, 1)
                                               for ts in (cutoff - HOUR, cutoff, radar.hour - HOUR)}
            radar.ema_states["BTC-USDT-SWAP"] = (cutoff - HOUR, 100)
            radar.prune_cache()
            self.assertEqual([row[0] for row in radar.db.execute("SELECT hour FROM candles ORDER BY hour")], [cutoff, radar.hour - HOUR])
            self.assertEqual([row[0] for row in radar.db.execute("SELECT hour FROM oi_base")], [radar.hour])
            self.assertEqual([row[0] for row in radar.db.execute("SELECT inst_id FROM ema200")], ["BTC-USDT-SWAP"])
            self.assertEqual(set(radar.candles["BTC-USDT-SWAP"]), {cutoff, radar.hour - HOUR})

            async def check_rollover():
                paths = []
                real_sleep = asyncio.sleep

                async def scan(path, *_args):
                    paths.append(path)

                async def sleep(_delay):
                    await real_sleep(0)
                    if paths:
                        raise asyncio.CancelledError

                radar.scan = scan
                with patch("backend.radar.asyncio.sleep", sleep), patch("backend.radar.time.time", return_value=(radar.hour + HOUR) / 1000):
                    with self.assertRaises(asyncio.CancelledError):
                        await radar.clock_loop()
                    await real_sleep(0)
                self.assertEqual(set(paths), {"/market/candles", "/rubik/stat/contracts/open-interest-history"})
                self.assertEqual(list(radar.db.execute("SELECT hour FROM oi_base")), [])
                self.assertIsNone(radar.rows["BTC-USDT-SWAP"]["oiBase"])

            asyncio.run(check_rollover())
            radar.db.close()


if __name__ == "__main__":
    unittest.main()
