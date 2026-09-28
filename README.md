# Perpetual Radar

Perpetual Radar is a native macOS app for OKX's live, non-TradFi USDT perpetual swaps. Its AppKit window embeds a WebKit dashboard built with shadcn/ui and Tailwind CSS. Swift collects public OKX REST and WebSocket data, computes the one-hour indicators, and stores completed data in SQLite. The app does not run a local web server or need an OKX API key.

## Features

- Covers live USDT-settled perpetual swaps, excluding TradFi instruments and `USDC-USDT-SWAP`. **Settings** lets you choose a minimum 24-hour turnover of 10 million (default), 30 million, or 100 million USDT, plus an optional maximum bid-ask spread (enabled by default at 0.15%). Settings persist across restarts; ticker data refreshes every 30 seconds.
- Ranks markets by a 0–100 momentum score derived from absolute ROC and MAROC ranks, positive open-interest change during OI `Building`, and positive hourly quote-volume change. Search markets and sort by column headings.
- Shows `LONG` or `SHORT` when price versus VWAP14, EMA200, and the Bollinger middle band agrees with EMA200 slope, ROC, MAROC, and taker direction. OI Signal describes the position cycle and does not determine long or short direction. `TRAP` appears in the same list.
- Displays price and previous-hour change, 48-hour high and low, OI Signal (`Stable`, `Building`, `Peaking`, `Unwinding`), taker metrics, ROC/MAROC, RSI (6/12/24), and Bollinger bands.
- Click a symbol for an in-app chart of the latest 96 one-hour candles, VWAP14, EMA200, Bollinger bands, volume, RSI, ROC/MAROC, open interest, and taker buy/sell volume. Chart history loads on demand and refreshes while open.
- Uses nine one-hour periods for ROC and MAROC.
- Permanently stores completed one-hour candles, hourly open-interest values, taker volumes, EMA200 state, and chart statistics in SQLite under Application Support for future backtesting. The live calculations load only their recent window into memory.
- Checks a small GitHub release manifest every three minutes without using the GitHub API. Use **Perpetual Radar → Check for Updates** to check immediately, then confirm to download, install, and relaunch a verified update. If GitHub limits requests, checks pause until its retry time.

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

Pushes to `main` build and publish `Perpetual.Radar.app.tar` plus `update.json` as the GitHub `autobuild` release. The updater uses the manifest's SHA-256 digest and the bundle's commit revision to verify the package.

## Test

```sh
npm test
npm run lint
```

The Swift code is in [`Sources/PerpetualRadar`](Sources/PerpetualRadar). The WebKit dashboard is in [`src`](src). `swift test` covers indicator behavior and SQLite persistence; the TypeScript tests cover ranking and filtering.
