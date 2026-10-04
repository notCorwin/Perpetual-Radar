# Perpetual Radar

Perpetual Radar is a native macOS app for OKX's live, non-TradFi USDT perpetual swaps. Its AppKit window embeds a WebKit dashboard built with shadcn/ui and Tailwind CSS. Swift collects public OKX REST and WebSocket data, computes the one-hour indicators, and stores completed data in SQLite. The app does not run a local web server or need an OKX API key.

## Features

- Covers live USDT-settled perpetual swaps, excluding TradFi instruments and `USDC-USDT-SWAP`. **Settings** lets you choose a minimum 24-hour turnover of 10 million (default), 30 million, or 100 million USDT, plus an optional maximum bid-ask spread (enabled by default at 0.15%). Settings persist across restarts; ticker data refreshes every 30 seconds.
- Ranks Long and Short markets together by **Opportunity** by default, identifying early `Startup` and trend `Pullback` setups from existing live one-hour indicators. Keeps every eligible market visible, ordered `Candidate`, `Watch`, `Overheated`, then `Incomplete`. The Opportunity column, immediately after Turnover, shows direction, score, setup and status. Open its score with the mouse, Enter or Space to inspect the scoring breakdown and reasons; Escape closes the details and restores focus. Search does not change scores. All indicator headings remain sortable, and sorting stays in memory, resetting to Opportunity on restart.
- All change rates use `D = (b − a) / |a|`, where `a` is the previous value and `b` is the current value, and display `D × 100%` with two decimal places. Doubling OI gives `+100.00%`, halving gives `−50.00%`, and unchanged OI gives `0.00%`. If `a = 0`, the reading is `0.00%` when `b = 0`, `+∞%` when `b > 0`, and `−∞%` when `b < 0`. Negative previous values also use their absolute magnitude as the denominator. Missing or invalid input readings display as `—`; infinities sort above or below all finite values, with missing readings last.
- Shows an EMA200 signal immediately to the right of Turnover. The live one-hour candle's body (open to close) entirely above the current EMA200 shows `Long`; entirely below shows `Short`; crossing or touching the line shows `Unsure`. Wicks do not affect the signal. The EMA includes the live close, matching the chart, and the signal updates as the candle changes. Missing live candles or insufficient EMA history show `—`. Click the heading to sort Long, Unsure, Short, or reverse the order; missing readings stay last. Signals remain in memory.
- Displays price and its change from the previous completed hour using the same formula. A move from 100 to 80 shows `−20.00%`, and the reverse move shows `+25.00%`. ROC uses the same formula over nine hours; MAROC averages nine hourly ROC readings. Both indicators and their hourly changes display as percentages in the list, and chart ROC/MAROC legends and scales use percentage units. Also displays the latest 48-hour high breakout and low breakdown, taker metrics, RSI (6/12/24), and a two-line Log BB summary. `Live > Upper`, `Live > Middle`, or `Live > Lower` shows only the highest 20-hour log-price band strictly below the live price; `Live ≤ Lower` means none is below it. `Expansion 3h` counts consecutive hourly increases in Band Width (`(Upper − Lower) / Middle × 100%`), including the current live candle; a flat or shrinking width resets to `0h`. The current hour can change before it closes. Both readings are sortable, with missing values last; `≥` marks a known minimum when older history cannot establish the run's start, and `—` means insufficient data. These live summaries stay in memory. Other indicators appear as soon as their own periods have enough data.
- Searches high breakouts and low breakdowns independently across the current hourly candle and the previous 47 candles. A candle's High must strictly exceed the highest High of its preceding 48 completed candles, or its Low must strictly fall below their lowest Low. Equal prices do not count. `↑ 3h ago · 37h old` means the latest high breakout happened in the candle starting three hours ago, and the previous high was 37 hours old at that break. Tied prior extremes use their most recent occurrence. Current-hour wicks count immediately and show `Live`; a later price retreat does not undo the break. Hover for the event's hourly interval, previous extreme price, and its formation hour, in local time. Sort each direction by break time (newest first on the first click) or prior extreme age (longest first); missing values always sort last.
- Shows `—` when there is no break in the search window or fewer than 48 completed listing candles, with distinct hover explanations. Incomplete history shows `Loading` until the latest break can be established. A partial first listing hour counts as one completed candle after it closes; the comparison window is never shortened for new contracts. Break results are computed in Swift and kept in memory.
- Click a symbol for an in-app chart showing 96 one-hour candles at a time, VWAP14, EMA200, Log BB, RSI, ROC/MAROC, open interest, and taker buy/sell volume. Price uses a logarithmic vertical axis and open interest uses a zero-inclusive logarithmic axis; RSI, ROC/MAROC, and taker volume use linear axes. Hold the primary mouse button to inspect a candle's OHLC and indicators, drag while holding to inspect other candles, and release to return to the window's latest candle. Hovering leaves the readings unchanged. Scroll the chart to review older OKX history; returning to the newest candle resumes automatic following when the next candle appears. Older candles are cached in SQLite as needed, and unavailable open-interest or taker data appears as a gap. Up/Down cycles through charts in the current visible market list order, wrapping between the first and last. Left jumps to the first market in the current sorted search results and Right jumps to the highest 24-hour turnover market among eligible contracts regardless of search. Nearby charts load and render in the background.
- Uses nine one-hour periods for ROC and MAROC.
- Permanently stores completed one-hour candles, hourly open-interest values, taker volumes, EMA200 state, and chart statistics in SQLite under Application Support for future backtesting. The live calculations load only their recent window into memory.
- Checks a small GitHub release manifest every 15 seconds without using the GitHub API. Automatic installation is enabled by default: a verified update downloads, installs, and relaunches the app. Turn it off with **Perpetual Radar → Automatically Install Updates**; **Check for Updates** remains available for a manual check. If GitHub limits requests, checks pause until its retry time.

The list shows all eligible contracts together. New markets and indicators appear as OKX history loads. Missing values display as `—`. The collector reconnects WebSocket subscriptions and retries failed history requests.

## Opportunity ranking

The score uses the current live snapshot and updates whenever its indicators change. EMA200 `Long` or `Short` supplies the direction. For Short, RSI becomes `100 − RSI`, and ROC, MAROC, hourly price change and taker imbalance change sign. OI change keeps its sign and measures participation, not direction. Log BB `below/lower/middle/upper` maps to `B = 0/1/2/3` for Long and the reverse for Short; existing band boundary definitions are preserved. All thresholds below use those directional values.

| Setup | Required readings |
| --- | --- |
| Startup | RSI24 > 50; ROC ≥ MAROC > 0; 50 ≤ RSI6 < 75; 50 ≤ RSI12 < 70; RSI6 > RSI12; B ≥ 2; a complete expansion run of 1–3h; positive price change or positive taker imbalance. |
| Pullback | RSI24 > 50; MAROC > 0; 40 ≤ RSI6 ≤ 60; 45 ≤ RSI12 ≤ 65; RSI6 ≤ RSI12; B is 1 or 2; both price change and taker imbalance are positive. |

Pullback identifies cooling inside the bands with live recovery using the current readings. It does not measure a specific support price or distance from a moving average. An `Unsure` EMA200 with complete core data is a zero-point Watch with no direction or setup.

| Score group | Points |
| --- | --- |
| Trend, up to 30 | Clear EMA200 direction: 15. Positive ROC, positive MAROC and RSI24 > 50: 5 each. |
| Entry, up to 30 | Matching either setup: 20. Both price and taker confirmation: 10; only one: 5. |
| Participation, up to 20 | Positive directional taker imbalance increases linearly from 0 to 10 points between 0% and 20%. Positive OI change increases linearly from 0 to 10 points between 0% and 5%. Larger readings are capped; zero or negative readings earn no bonus. |
| Timing, up to 20 | Same-direction breakout/breakdown 0–3h ago: 10; 4–12h ago: 5. For Startup or no setup, complete expansion 1–3h: 10; 4–6h: 5. For Pullback, complete expansion 0–2h: 10; 3–5h: 5. |
| Heat penalty, up to 40 | Deduct 10 each for RSI6 ≥ 70, RSI12 ≥ 65, B = 3 and expansion ≥ 4h. |

Clamp the total to 0–100, then round to the nearest integer. A matching setup with at least 65 points is a Candidate unless an overheating combination is present. Otherwise, a valid directional result is Watch. Any of these combinations makes it Overheated regardless of score:

- RSI6 ≥ 80 together with RSI12 ≥ 70.
- B = 3 together with RSI6 ≥ 75.
- B = 3, expansion ≥ 6h and RSI12 ≥ 65 together.

An outer-band reading alone contributes a penalty without classifying the market as Overheated. Missing, loading or old breaks earn no timing bonus. An expansion lower bound (`≥`) earns no expansion timing bonus and cannot establish a Startup, but a sufficiently long lower bound still contributes heat deductions and overheating checks.

Missing or invalid EMA200, price change, ROC, MAROC, RSI6/12/24, Log BB position or expansion produces an unscored Incomplete result. Non-finite core readings are treated as unavailable. Missing or non-finite OI/taker readings earn zero participation points without redistributing weights; details explain the missing inputs. Original indicator columns retain their infinity display and numeric sorting.

Opportunity ordering compares status first, score second, then descending turnover and instrument ID. Reverse sorting reverses valid statuses and scores while keeping Incomplete results last. Scores are computed before search, held only in memory and require no new OKX requests or database changes. These balanced weights and thresholds are initial heuristics and have not been calibrated through backtesting.

## Requirements

- macOS 14 or newer, Xcode 26.3 or newer, Node.js 22.12 or newer, and npm
- Network access to OKX public REST and WebSocket endpoints

## Build and run

```sh
npm ci
npm run app
open ".build/app/Perpetual Radar.app"
```

`npm run app` compiles the dashboard and Swift executable, then creates an ad hoc signed `.app` bundle. The first launch loads one-hour history across eligible contracts, so some indicators take time to appear. Click a symbol to open its chart in the app. The app stores its SQLite cache at `~/Library/Application Support/PerpetualRadar/radar.sqlite3`.

Run `npm run ci:local` before pushing to complete CI locally: Swift and TypeScript tests, lint, and a full macOS app build. GitHub Actions handles CD: pushes to `main` build the release package and replace the single GitHub `autobuild` release and tag. Actions does not run the test or lint suites. The release contains only the latest `Perpetual.Radar.app.tar` and `update.json`; previous build assets are removed after the new package is verified and its manifest is published. The release notes show the latest build time, commit, and download link. The updater uses the manifest's SHA-256 digest and the bundle's commit revision to verify the package.

## Test

```sh
npm run ci:local
```

To run the test and lint suites separately:

```sh
npm test
npm run lint
```

The Swift code is in [`Sources/PerpetualRadar`](Sources/PerpetualRadar). The WebKit dashboard is in [`src`](src). `swift test` covers indicator behavior and SQLite persistence; the TypeScript tests cover ranking, filtering, and chart geometry.
