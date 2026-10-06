# Perpetual Radar

Perpetual Radar is a native macOS app for OKX's live, non-TradFi USDT perpetual swaps. Its AppKit window embeds a WebKit dashboard built with shadcn/ui and Tailwind CSS. Swift collects public OKX REST and WebSocket data, computes the one-hour indicators, and stores completed data in SQLite. The app does not run a local web server or need an OKX API key.

## Features

- A native frosted window background is enabled by default with **0.3 background opacity** and **Dark appearance**. Dark glass uses Ghostty's neutral `#282c34` tint with opaque white text, preserving the desktop colors instead of washing them out with a white fill. It uses the same untinted WindowServer blur and radius of 20 as Ghostty's `background-blur = true`, with a single background layer rather than an additional AppKit material tint. Under **Settings**, turn **Frosted background** on or off and set **Background opacity** from 0 to 1. Lower values reveal more of the blurred desktop; 1 uses a solid theme background and removes the blur. The native **Appearance** menu retains Light, Dark, and System choices, and existing choices are preserved. Light appearance intentionally uses a light tint. Text and chart lines stay opaque. Both background settings persist in SQLite and restore on restart; disabling the effect retains the chosen opacity. Blur restores when the window becomes active, after wake, and across fullscreen transitions. AppKit provides fallback blur if WindowServer blur is unavailable.
- Controls, menus, badges, table highlights, and chart annotations share the appearance tokens in `src/index.css`. Form controls use the same height, radius, system typography, and keyboard focus treatment; ordinary column titles use the system font while mathematical formulas retain KaTeX. Floating menus blur the app content beneath them and keep a denser tint for legibility. Their tint and blur follow background opacity, with solid surfaces when the effect is disabled or opacity is 1. Popovers fit the available window height and scroll when necessary. System Reduce Motion applies to controls, menus, and loading indicators.
- Covers every live, non-TradFi USDT perpetual swap. Turnover, spread, listing age and the `USDC-USDT-SWAP` exclusion are visible, editable rules within each combination. First-launch defaults are turnover ≥ 10M USDT, spread ≤ 0.15%, listing age ≥ 6 Gregorian calendar months, and the symbol exclusion. Clearing the entire tree shows every contract in the exchange universe, including markets with incomplete readings. Quotes refresh every 30 seconds.
- **Filters** offers synchronized **Rules** and **Formula** views. Nest AND/OR/NOT groups, duplicate or reorder branches, select Live or Closed per rule, search all supported indicator fields, and use parameterized indicators and named expressions on either side of a comparison. Temporal rules include consecutive hours, recent occurrences, counts, crossings and ordered event sequences with frozen reference captures. Valid edits immediately preview the same native matches used by the list and every chart navigation direction. Invalid drafts retain the last valid preview and cannot be applied or saved. Draft source, names and collapsed nodes survive view changes and chart navigation.
- **Explain markets** includes matching, unmatched and Unknown contracts. Each explanation shows actual operands, thresholds, hourly event times, captured levels and data gaps. Swift performs parsing, validation, calculations, Opportunity scoring and three-state evaluation; WebKit edits and displays its results. Only True enters the list. Missing data stays Unknown under NOT; Available/Unavailable rules explicitly query it.
- Ranks Long and Short markets together by **Opportunity** by default, identifying early `Startup` and trend `Pullback` setups from existing live one-hour indicators. With no search or indicator conditions, keeps every eligible market visible, ordered `Candidate`, `Watch`, `Overheated`, then `Incomplete`. The Opportunity column, immediately after Turnover, shows direction, score, setup and status. Open its score with the mouse, Enter or Space to inspect the scoring breakdown and reasons; Escape closes the details and restores focus. Search and filters do not change scores. All indicator headings remain sortable, and sorting stays in memory, resetting to Opportunity on restart.
- All change rates use `D = (b − a) / |a|`, where `a` is the previous value and `b` is the current value, and display `D × 100%` with two decimal places. Doubling OI gives `+100.00%`, halving gives `−50.00%`, and unchanged OI gives `0.00%`. If `a = 0`, the reading is `0.00%` when `b = 0`, `+∞%` when `b > 0`, and `−∞%` when `b < 0`. Negative previous values also use their absolute magnitude as the denominator. Missing or invalid input readings display as `—`; infinities sort above or below all finite values, with missing readings last.
- Uses EMA200 to determine the direction shown in Opportunity. The live one-hour candle's body (open to close) entirely above the current EMA200 gives `Long`; entirely below gives `Short`; crossing or touching the line gives `Unsure`. Wicks do not affect the signal. The EMA includes the live close, matching the chart, and the signal updates as the candle changes. `Unsure` yields a directionless `Watch` score of 0 when required metrics are complete; missing live candles or insufficient EMA history yield `Incomplete`. Signals remain in memory, and EMA200 remains visible on the chart.
- Displays price and its change from the previous completed hour using the same formula. A move from 100 to 80 shows `−20.00%`, and the reverse move shows `+25.00%`. ROC uses the same formula over nine hours; MAROC averages nine hourly ROC readings. Both indicators and their hourly changes display as percentages in the list, and chart ROC/MAROC legends and scales use percentage units. Also displays the latest 48-hour high breakout and low breakdown, taker metrics, RSI (6/12/24), and a two-line Log BB summary. `Live > Upper`, `Live > Middle`, or `Live > Lower` shows only the highest 20-hour log-price band strictly below the live price; `Live ≤ Lower` means none is below it. `Expansion 3h` counts consecutive hourly increases in Band Width (`(Upper − Lower) / Middle × 100%`), including the current live candle; a flat or shrinking width resets to `0h`. The current hour can change before it closes. Both readings are sortable, with missing values last; `≥` marks a known minimum when older history cannot establish the run's start, and `—` means insufficient data. These live summaries stay in memory. Other indicators appear as soon as their own periods have enough data.
- Searches high breakouts and low breakdowns independently across the current hourly candle and the previous 47 candles. A candle's High must strictly exceed the highest High of its preceding 48 completed candles, or its Low must strictly fall below their lowest Low. Equal prices do not count. `↑ 3h ago · 37h old` means the latest high breakout happened in the candle starting three hours ago, and the previous high was 37 hours old at that break. Tied prior extremes use their most recent occurrence. Current-hour wicks count immediately and show `Live`; a later price retreat does not undo the break. Hover for the event's hourly interval, previous extreme price, and its formation hour, in local time. Sort each direction by break time (newest first on the first click) or prior extreme age (longest first); missing values always sort last.
- Shows `—` when there is no break in the search window or fewer than 48 completed listing candles, with distinct hover explanations. Incomplete history shows `Loading` until the latest break can be established. A partial first listing hour counts as one completed candle after it closes; the comparison window is never shortened for new contracts. Break results are computed in Swift and kept in memory.
- Click a symbol for an in-app chart showing 96 one-hour candles at a time, VWAP14, EMA200, Log BB, RSI, ROC/MAROC, open interest, and taker buy/sell volume. Price uses a logarithmic vertical axis and open interest uses a zero-inclusive logarithmic axis; RSI, ROC/MAROC, and taker volume use linear axes. Hold the primary mouse button to inspect a candle's OHLC and indicators, drag while holding to inspect others, and release to return to the window's latest candle. Hovering leaves the readings unchanged. Scroll the chart to review older OKX history; returning to the newest candle resumes automatic following when the next candle appears. Older candles are cached in SQLite as needed, and unavailable open-interest or taker data appears as a gap. Up/Down cycles through charts in the current visible market list order, wrapping between the first and last. Left jumps to the first market in the current sorted search results and Right jumps to the highest 24-hour turnover market satisfying the current valid rule preview, regardless of search. Nearby charts load and render in the background.
- Uses nine one-hour periods for ROC and MAROC.
- Permanently stores completed one-hour candles, hourly open-interest values, taker volumes, EMA200 state, and chart statistics in SQLite under Application Support for future backtesting. The live calculations load only their recent window into memory.
- Checks a small GitHub release manifest every 15 seconds without using the GitHub API. Automatic installation is enabled by default: a verified update downloads, installs, and relaunches the app. Turn it off with **Perpetual Radar → Automatically Install Updates**; **Check for Updates** remains available for a manual check. If GitHub limits requests, checks pause until its retry time.

The list shows all matching contracts together. New markets and indicators appear as OKX history loads. Missing values display as `—`. The collector reconnects WebSocket subscriptions and retries failed history requests.

## List filters


Open **Filters** to edit its tree or formula. All numeric values display units: turnover uses M USDT, OI uses M USD, prices and quote volume use USDT, change rates use percent, and RSI uses 0–100. Formula completion is available through the metric/function picker or Ctrl+Space and inserts concrete defaults. Functions accept explicit periods; defaults match the existing list (EMA200, RSI6/12/24, ROC9, MAROC9/9, Log BB20/2, VWAP14, break reference48/96 and event search48).

In **Rules**, the expression picker includes arithmetic and every scalar function. **Transform expression…** wraps the current operand in a function or arithmetic operation; expand its parameters to edit nested source expressions and numeric windows. For relative volume, select **Volume** on the left, **Greater than >**, and **Mean** on the right. Change the mean's source to **Historical offset** (Volume, 1 hour), retain its 20-hour window, then transform the mean with **Multiply ×** and a right operand of 2. Category fields, including named category formulas, offer direct values such as **OI trend → Equals → Rising**. Contract symbols offer a plain text value or a custom expression. Both previous high and previous low ages at a break are searchable fields.

**Wrap in…** offers NOT, Every hour, Recently, Occurrence count, AND and OR groups. **Remove wrapper** retains the enclosed rule and its hourly data selection. Wrapping a sequence stage preserves its Closed anchor, identifier, gap and captures, so captured prices use the same event hour as the original stage condition. Crossing rules expose two operands and their equality boundary; range endpoints appear only for range comparisons.

```text
// Long or short alignment
(emaTrend == "rising" AND ROC(9) > 0)
OR (emaTrend == "falling" AND ROC(9) < 0)

// Live volume exceeds twice the mean of the previous 20 closed candles
let relativeVolume = Volume / mean(lag(Volume, 1), 20);
relativeVolume > 2

// Each of the latest three completed RSI hours meets the threshold
closed(every(RSI(14) > 50, 3))

// Break, retest and reclaim a captured reference within six hours
sequence(6,
  stage("break", High > PriorHigh(48), 6, capture("level", PriorHigh(48))),
  stage("retest", Low <= break.level, 6),
  stage("reclaim", crossUp(Close, break.level), 6)
)
```

Each example is a separate configuration. Prefix reusable definitions with `let name = expression;`. Scalar functions include arithmetic, `abs`, `mean`, `sum`, `highest`, `lowest`, `stddev` (population), `lag` and `change`. Names and comparison types are checked by Swift, including definition cycles and event capture scope. `named("label", rule)` retains a visual rule name in formula form. Indicator parameters and temporal windows are positive whole hours; Log BB deviations may be any positive number. `lag(x, 0)` is allowed. Nested groups retain their order and identities when switching views.

Live reads the current hourly slot; Closed shifts its rule one hour back. Each additional Closed wrapper adds an offset. `every`/`recent`/`count` include their anchor and preceding slots; gaps are not skipped. Count syntax is `count(rule, hours, "gte", minimum)` or `count(rule, hours, "between", minimum, maximum)`. Unknown slots represent possible matches, so a count is True or False only when every possible count agrees. `crossUp(a,b)` requires previous `a ≤ b` and current `a > b`; `crossDown` uses previous `a ≥ b` and current `a < b`.

Sequence stages occur in strictly different hourly slots. A stage's gap applies from the preceding stage, the total span bounds first-to-last elapsed hours, and the final stage anchors the sequence (the previous completed hour if that stage is Closed). Earlier paths remain eligible when a newer possible start cannot complete. Captures are numeric event-hour values accessible to later stages as `stageName.captureName`. Use `recent(sequence(...), hours)` to search for earlier completed sequences. Captures, traces and matches stay in memory.

The loader derives history demand from periods, offsets and windows, reads SQLite first and pages missing OKX history in the background. Identical indicators share calculation caches, and overlapping history requests share stored pages. There is no 250-hour rule window ceiling. Existing RSI/EMA warm-up conventions remain intact; insufficient listing history and unavailable exchange history remain Unknown. Closed turnover and spread snapshots accumulate from observed ticker quotes after this upgrade; earlier hours remain Unknown. Observations are never filled with zeros or copied into another hour.

**Apply filters** saves the valid configuration to SQLite. **Reset draft** previews an empty tree; **Discard changes** restores the applied configuration. Saved combinations retain name, identity, node order, formulas and selected state; saving an existing case-insensitive name updates that entry. Reload a selected combination to recover its saved tree, or delete it while retaining the draft. The applied v1 configuration and every saved combination migrate transactionally to v2, with the old AND/OR tree inside an outer AND containing the former base gates. The former spread gate’s 1e-10 rounding tolerance is preserved as an editable `threshold + 1e-10` expression. A failed migration or save rolls back the configuration and selection for retry. Runtime previews and live readings are never persisted.

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

Opportunity ordering compares status first, score second, then descending turnover and instrument ID. Reverse sorting reverses valid statuses and scores while keeping Incomplete results last. Scores are computed before search and indicator filters, held only in memory and require no new OKX requests or database changes. These balanced weights and thresholds are initial heuristics and have not been calibrated through backtesting.

## Requirements

- macOS 14 or newer, Xcode 26.3 or newer, Node.js 22.12 or newer, and npm
- Network access to OKX public REST and WebSocket endpoints

## Build and run

```sh
npm ci
npm run app
open ".build/app/Perpetual Radar.app"
```

`npm run app` compiles the dashboard and Swift executable, then creates an ad hoc signed `.app` bundle. The first launch loads one-hour history across the exchange universe, so some indicators take time to appear. Click a symbol to open its chart in the app. The app stores its SQLite cache and applied Filter configuration at `~/Library/Application Support/PerpetualRadar/radar.sqlite3`.

The market list fills the window width, using a minimum design width of 1600 points and enough room for the widest loaded row. In narrower windows, the toolbar and table scale together after layout, preserving columns and formula rendering. The chart toolbar keeps its title and description on one line, with full text available on hover, so smaller windows retain room for the plot. Data refreshes preserve the window size you choose.

Run `npm run ci:local` before pushing to complete CI locally: Swift and TypeScript tests, lint, a full macOS app build, and native WKWebView interaction checks with 500 simulated markets. GitHub Actions handles CD: pushes to `main` build the release package and replace the single GitHub `autobuild` release and tag. Actions does not run the test or lint suites. The release contains only the latest `Perpetual.Radar.app.tar` and `update.json`; previous build assets are removed after the new package is verified and its manifest is published. The release notes show the latest build time, commit, and download link. The updater uses the manifest's SHA-256 digest and the bundle's commit revision to verify the package.

## Test

```sh
npm run ci:local
```

To run the test and lint suites separately:

```sh
npm test
npm run lint
npm run test:ui
```

The Swift code is in [`Sources/PerpetualRadar`](Sources/PerpetualRadar). The WebKit dashboard is in [`src`](src). `swift test` covers the rule compiler/evaluator, sequences, history paging, migration/rollback, indicator behavior and SQLite persistence. Compatibility fixtures verify all legacy fields and native Opportunity against 172 frozen Web results. TypeScript tests cover editor operations, response ordering, legacy reference behavior and chart geometry. `npm run test:ui` builds the renderer and exercises the actual radar:// WKWebView bridge, saving review snapshots in `.build/ui-qa`. Local CI runs these UI checks after the packaged app build; GitHub Actions remains release-only.
