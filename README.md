# Perpetual Radar

Perpetual Radar is a native macOS app for OKX's live, non-TradFi USDT perpetual swaps. Its AppKit window embeds a WebKit dashboard built with shadcn/ui and Tailwind CSS. Swift collects public OKX REST and WebSocket data, computes the one-hour indicators, and stores completed data in SQLite. The app does not run a local web server or need an OKX API key.

## Features

- Covers live USDT-settled perpetual swaps, excluding TradFi instruments and `USDC-USDT-SWAP`. **Settings** lets you choose a minimum 24-hour turnover of 10 million (default), 30 million, or 100 million USDT, plus an optional maximum bid-ask spread (enabled by default at 0.15%). Settings persist across restarts; ticker data refreshes every 30 seconds.
- Ranks markets by a 0–100 momentum score derived from absolute ROC and MAROC ranks, positive open-interest change, and positive hourly quote-volume change. Search markets and sort by column headings.
- Shows `LONG` or `SHORT` when price versus VWAP14, EMA200, and the Bollinger middle band agrees with taker direction. `TRAP` contracts are hidden by default; **Only TRAP** shows them, including contracts with opposite ROC and MAROC signs.
- Displays price and previous-hour change, 48-hour high and low, open-interest and taker metrics, ROC/MAROC, RSI (6/12/24), and Bollinger bands.
- Uses nine one-hour periods for ROC and MAROC.
- Stores completed one-hour candles, EMA200 state, and hourly open-interest baselines in Application Support. It reuses settled data after a restart and removes expired entries automatically.
- Checks the GitHub autobuild release every three minutes. Use **Perpetual Radar → Check for Updates** to check immediately, then confirm to download, install, and relaunch a verified update.

The list hides contracts whose available ROC and MAROC have opposite signs and contracts classified as `TRAP`, unless **Only TRAP** is selected. New markets and indicators appear as OKX history loads. Missing values display as `—`. The collector reconnects WebSocket subscriptions and retries failed history requests.

## Requirements

- macOS 14 or newer, Xcode 26.3 or newer, Node.js 22.12 or newer, and npm
- Network access to OKX public REST and WebSocket endpoints

## Build and run

```sh
npm ci
npm run app
open ".build/app/Perpetual Radar.app"
```

`npm run app` compiles the dashboard and Swift executable, then creates an ad hoc signed `.app` bundle. The first launch loads one-hour history across eligible contracts, so some indicators take time to appear. Click a symbol to open its OKX chart in the default browser. The app stores its SQLite cache at `~/Library/Application Support/PerpetualRadar/radar.sqlite3`.

Pushes to `main` build and publish `Perpetual.Radar.app.tar` as the GitHub `autobuild` release. The updater uses the release's SHA-256 digest and the bundle's commit revision to verify the package.

## Test

```sh
npm test
npm run lint
```

The Swift code is in [`Sources/PerpetualRadar`](Sources/PerpetualRadar). The WebKit dashboard is in [`src`](src). `swift test` covers indicator behavior and SQLite persistence; the TypeScript tests cover ranking and filtering.
