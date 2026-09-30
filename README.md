# Perpetual Radar

Perpetual Radar is a native macOS app for OKX's live, non-TradFi USDT perpetual swaps. Its AppKit window embeds a WebKit dashboard built with shadcn/ui and Tailwind CSS. Swift collects public OKX REST and WebSocket data, computes the one-hour indicators, and stores completed data in SQLite. The app does not run a local web server or need an OKX API key.

## Features

- Covers live USDT-settled perpetual swaps, excluding TradFi instruments and `USDC-USDT-SWAP`. **Settings** lets you choose a minimum 24-hour turnover of 10 million (default), 30 million, or 100 million USDT, plus an optional maximum bid-ask spread (enabled by default at 0.15%). Settings persist across restarts; ticker data refreshes every 30 seconds.
- Ranks markets by 24-hour USDT turnover. Search markets and sort by numeric column headings.
- Displays price and previous-hour change, 96-hour high and low with current-price Log Change (`ln(price / extreme)`) and each extreme’s candle age in hours (most recent occurrence for ties), taker metrics, ROC/MAROC, RSI (6/12/24), and Log BB (20-hour bands calculated in log-price space).
- Click a symbol for an in-app chart showing 96 one-hour candles at a time, VWAP14, EMA200, Log BB, RSI, ROC/MAROC, open interest, and taker buy/sell volume. Price uses a logarithmic vertical axis and open interest uses a zero-inclusive logarithmic axis; RSI, ROC/MAROC, and taker volume use linear axes. Scroll the chart to review older OKX history; returning to the newest candle resumes automatic following when the next candle appears. Older candles are cached in SQLite as needed, and unavailable open-interest or taker data appears as a gap. Up/Down cycles through charts in the current visible market list order, wrapping between the first and last. Left jumps to the highest-turnover market, Right jumps to the lowest-turnover market, and Shift+Left/Right inspects candles. Nearby charts load and render in the background.
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

Pushes to `main` update the single GitHub `autobuild` release and tag. It contains `Perpetual.Radar.app.tar`, `update.json`, and revision-specific app archives retained for seven days. The updater uses the manifest's SHA-256 digest and the bundle's commit revision to verify the package.

## Test

```sh
npm test
npm run lint
```

The Swift code is in [`Sources/PerpetualRadar`](Sources/PerpetualRadar). The WebKit dashboard is in [`src`](src). `swift test` covers indicator behavior and SQLite persistence; the TypeScript tests cover ranking, filtering, and chart geometry.
