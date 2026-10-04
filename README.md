# Perpetual Radar

Perpetual Radar is a native macOS app for OKX's live, non-TradFi USDT perpetual swaps. Its AppKit window embeds a WebKit dashboard built with shadcn/ui and Tailwind CSS. Swift collects public OKX REST and WebSocket data, computes the one-hour indicators, and stores completed data in SQLite. The app does not run a local web server or need an OKX API key.

## Features

- Covers live USDT-settled perpetual swaps, excluding TradFi instruments and `USDC-USDT-SWAP`. **Settings** lets you choose a minimum 24-hour turnover of 10 million (default), 30 million, or 100 million USDT, plus an optional maximum bid-ask spread (enabled by default at 0.15%). Settings persist across restarts; ticker data refreshes every 30 seconds.
- Ranks markets by Log OI (OI Log Change) in descending order by default, displaying `ln(OI_t / OI_{t-1}) × 100`. Search markets and sort by numeric column headings. Sorting stays in memory and resets to the default on restart.
- Displays price and previous-hour change, the latest 48-hour high breakout and low breakdown, taker metrics, ROC/MAROC, RSI (6/12/24), and a two-line Log BB summary. `Live > Upper`, `Live > Middle`, or `Live > Lower` shows only the highest 20-hour log-price band strictly below the live price; `Live ≤ Lower` means none is below it. `Expansion 3h` counts consecutive hourly increases in Band Width (`(Upper − Lower) / Middle × 100%`), including the current live candle; a flat or shrinking width resets to `0h`. The current hour can change before it closes. Both readings are sortable, with missing values last; `≥` marks a known minimum when older history cannot establish the run's start, and `—` means insufficient data. These live summaries stay in memory. Other indicators appear as soon as their own periods have enough data.
- Searches high breakouts and low breakdowns independently across the current hourly candle and the previous 47 candles. A candle's High must strictly exceed the highest High of its preceding 48 completed candles, or its Low must strictly fall below their lowest Low. Equal prices do not count. `↑ 3h ago · 37h old` means the latest high breakout happened in the candle starting three hours ago, and the previous high was 37 hours old at that break. Tied prior extremes use their most recent occurrence. Current-hour wicks count immediately and show `Live`; a later price retreat does not undo the break. Hover for the event's hourly interval, previous extreme price, and its formation hour, in local time. Sort each direction by break time (newest first on the first click) or prior extreme age (longest first); missing values always sort last.
- Shows `—` when there is no break in the search window or fewer than 48 completed listing candles, with distinct hover explanations. Incomplete history shows `Loading` until the latest break can be established. A partial first listing hour counts as one completed candle after it closes; the comparison window is never shortened for new contracts. Break results are computed in Swift and kept in memory.
- Click a symbol for an in-app chart showing 96 one-hour candles at a time, VWAP14, EMA200, Log BB, RSI, ROC/MAROC, open interest, and taker buy/sell volume. Price uses a logarithmic vertical axis and open interest uses a zero-inclusive logarithmic axis; RSI, ROC/MAROC, and taker volume use linear axes. Hold the primary mouse button to inspect a candle's OHLC and indicators, drag while holding to inspect other candles, and release to return to the window's latest candle. Hovering leaves the readings unchanged. Scroll the chart to review older OKX history; returning to the newest candle resumes automatic following when the next candle appears. Older candles are cached in SQLite as needed, and unavailable open-interest or taker data appears as a gap. Up/Down cycles through charts in the current visible market list order, wrapping between the first and last. Left jumps to the first market in the current sorted search results and Right jumps to the highest 24-hour turnover market among eligible contracts regardless of search. Nearby charts load and render in the background.
- Uses nine one-hour periods for ROC and MAROC.
- Permanently stores completed one-hour candles, hourly open-interest values, taker volumes, EMA200 state, and chart statistics in SQLite under Application Support for future backtesting. The live calculations load only their recent window into memory.
- Checks a small GitHub release manifest every 15 seconds without using the GitHub API. Automatic installation is enabled by default: a verified update downloads, installs, and relaunches the app. Turn it off with **Perpetual Radar → Automatically Install Updates**; **Check for Updates** remains available for a manual check. If GitHub limits requests, checks pause until its retry time.

The list shows all eligible contracts together. New markets and indicators appear as OKX history loads. Missing values display as `—`. The collector reconnects WebSocket subscriptions and retries failed history requests.

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

Pushes to `main` automatically build and replace the single GitHub `autobuild` release and tag. It contains only the latest `Perpetual.Radar.app.tar` and `update.json`; previous build assets are removed after the new package is verified and its manifest is published. The release notes show the latest build time, commit, and download link. The updater uses the manifest's SHA-256 digest and the bundle's commit revision to verify the package.

## Test

```sh
npm test
npm run lint
```

The Swift code is in [`Sources/PerpetualRadar`](Sources/PerpetualRadar). The WebKit dashboard is in [`src`](src). `swift test` covers indicator behavior and SQLite persistence; the TypeScript tests cover ranking, filtering, and chart geometry.
