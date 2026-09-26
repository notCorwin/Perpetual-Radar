# Perpetual Radar

Perpetual Radar is a live, sortable dashboard for OKX's non-TradFi USDT perpetual swaps. It combines one-hour price, open-interest, and taker-volume data to surface contracts with strong momentum. The Python backend reads public OKX endpoints and WebSocket feeds; the React frontend refreshes its snapshot every two seconds. No OKX API key is required.

## Features

- Covers live USDT-settled perpetual swaps, excluding TradFi instruments and `USDC-USDT-SWAP`.
- Ranks markets by a 0–100 momentum score derived from absolute ROC and MAROC ranks, positive open-interest change, and positive hourly quote-volume change. Search markets and sort by the supported column headings.
- Shows `LONG` or `SHORT` when price versus VWAP14, EMA200, and the Bollinger middle band agrees with taker direction; contracts classified as `TRAP` are hidden.
- Displays price and previous-hour change, 48-hour high and low, open-interest and taker metrics, ROC/MAROC, RSI (6/12/24), and Bollinger bands.
- Lets users set ROC and MAROC periods from 1 to 100; the browser remembers those settings.
- Stores completed one-hour candles, EMA200 state, and hourly open-interest baselines in SQLite, so restarts can reuse settled data. At each hour change, the backend backfills any missed closing candles and removes expired cache entries.

By default, the list hides contracts whose available ROC and MAROC have opposite signs, and contracts classified as `TRAP`. New markets and indicators appear as OKX history loads. Missing values display as `—` until enough data is available. The backend reconnects its OKX WebSocket subscriptions and retries failed history requests.

The taker buy/sell ratio comes from OKX contract taker-volume history. The column labeled **Taker Log Change** uses the current versus previous one-hour candle's USDT quote volume.

## Requirements

- Python `>=3.14.7,<3.15` and [uv](https://docs.astral.sh/uv/)
- Node.js `>=22.12` and npm
- Network access to OKX public REST and WebSocket endpoints

## Run locally

Start the backend from the repository root:

```sh
uv sync
uv run perp-radar
```

In another terminal, start the frontend:

```sh
npm ci
npm run dev
```

Open <http://127.0.0.1:5173/>. Vite proxies `/api` to the backend at `127.0.0.1:8765`. The first run backfills one-hour history across all eligible contracts, so some values take time to appear. Click a symbol to open its OKX chart, click a column heading to sort, or use **Settings** to change the ROC and MAROC periods.

For backend auto-reload during development, run `uv run watchfiles --filter python backend.radar.main backend` in place of `uv run perp-radar`.

## Configuration

| Variable | Purpose | Default |
| --- | --- | --- |
| `HOST` | Backend bind address | `127.0.0.1` |
| `PORT` | Backend port | `8765` |
| `CACHE_PATH` | SQLite database path | `radar.sqlite3` |
| `ALLOWED_ORIGINS` | Comma-separated browser origins allowed to read the API | `http://127.0.0.1:5173,http://localhost:5173` |

For example, to store the cache outside the checkout:

```sh
CACHE_PATH=/var/lib/perp-radar/radar.sqlite3 uv run perp-radar
```

Keep that path on persistent storage when deploying the backend. The database is created automatically; current-hour values continue updating from OKX and are recalculated after a restart. Completed candles are retained for the 200-hour indicator window, and expired open-interest baselines and EMA states are removed automatically.

## Deploy on one host

Run `npm ci && npm run build`, then run `uv run perp-radar` as a persistent service. Serve `dist/` from the same HTTPS origin and proxy `/api/` to the backend at `127.0.0.1:8765`. Set `CACHE_PATH` to persistent storage so completed hourly data survives restarts.

## Develop and test

The backend is in [`backend/radar.py`](backend/radar.py); the dashboard and ranking logic are in [`src/App.tsx`](src/App.tsx) and [`src/market-sort.ts`](src/market-sort.ts). The UI uses React, shadcn/ui, and Tailwind CSS.

```sh
npm test       # Python indicator/API checks and TypeScript ranking checks
npm run lint  # oxlint
npm run build # TypeScript check and production build
```

## Help and contributions

For bugs, questions, and feature requests, open a [GitHub issue](https://github.com/notCorwin/Perpetual-Radar/issues). The repository is maintained by [@notCorwin](https://github.com/notCorwin). Contributions are welcome: describe the change in an issue or pull request and run the commands above before submitting.
