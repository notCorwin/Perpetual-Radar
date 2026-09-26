import { Fragment, useEffect, useMemo, useState } from "react"
import { ArrowDown, ArrowDownUp, ArrowUp, Radio, Search, Settings2 } from "lucide-react"
import katex from "katex"
import "katex/dist/katex.min.css"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Field, FieldGroup, FieldTitle } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Popover, PopoverContent, PopoverDescription, PopoverHeader, PopoverTitle, PopoverTrigger } from "@/components/ui/popover"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { cn } from "@/lib/utils"
import { compareMarketRows, marketTrend, matchesMarketFilter, momentumScores, type SortKey } from "@/market-sort"

type MarketRow = {
  instId: string
  price: number | null
  priceChange: number | null
  vwap14: number | null
  ema200: number | null
  ema200Slope: number | null
  oi: number | null
  oiBase: number | null
  oiLog: number | null
  oiUsd: number | null
  buy: number | null
  sell: number | null
  takerRatio: number | null
  volumeLog: number | null
  high48: number | null
  high48Diff: number | null
  low48: number | null
  low48Diff: number | null
  roc: number | null
  maroc: number | null
  rsi6: number | null
  rsi12: number | null
  rsi24: number | null
  bollUpper: number | null
  bollMiddle: number | null
  bollLower: number | null
  rocChange: number | null
  marocChange: number | null
}
type Snapshot = { rows: MarketRow[]; updatedAt: number | null; error: string; minimum24hTurnoverUSDT: number }
type NativeBridge = {
  postMessage(request: { rocPeriod: number; marocPeriod: number }): Promise<Snapshot>
  postMessage(request: { minimum24hTurnoverUSDT: number }): Promise<Snapshot>
  postMessage(request: { fitWidth: number }): Promise<{ ok: boolean }>
}
declare global {
  interface Window { webkit: { messageHandlers: { radar: NativeBridge } } }
}
const ROC_PERIOD = 9
const MAROC_PERIOD = 9
const formatLog = (value: number | null) => value === null ? "—" : value === 0
  ? "0.000000"
  : `${value > 0 ? "+" : ""}${Math.abs(value) < 0.000001 ? value.toExponential(2) : value.toFixed(6)}`
const formatPercent = (value: number | null) => value === null ? "—" : `${value > 0 ? "+" : ""}${value.toFixed(2)}%`
const formatIndicator = (value: number | null) => value === null ? "—" : value.toFixed(2)
const priceFormatter = new Intl.NumberFormat("en-US", { maximumSignificantDigits: 8 })
const formatPrice = (value: number | null) => value === null ? "—" : priceFormatter.format(value)
const directionClass = (value: number | null) => value === null ? "text-muted-foreground" : value > 0 ? "text-positive" : value < 0 ? "text-destructive" : ""
const rsiClass = (value: number | null) => value === null ? "text-muted-foreground" : value > 70 ? "text-positive" : value < 30 ? "text-destructive" : ""
const bollClass = (price: number | null, level: number | null) => price === null || level === null ? "text-muted-foreground" : price > level ? "text-positive" : "text-destructive"
const RSI_PERIODS = [6, 12, 24] as const
const BOLL_LINES = [{ label: "Upper", key: "bollUpper" }, { label: "Middle", key: "bollMiddle" }, { label: "Lower", key: "bollLower" }] as const
const math = (formula: string) => <span className="text-xs font-medium text-foreground" dangerouslySetInnerHTML={{ __html: katex.renderToString(formula) }} />
function App() {
  const [rows, setRows] = useState<MarketRow[]>([])
  const [status, setStatus] = useState("Connecting")
  const [error, setError] = useState("")
  const [updatedAt, setUpdatedAt] = useState<number | null>(null)
  const [query, setQuery] = useState("")
  const [trapOnly, setTrapOnly] = useState(false)
  const [minimum24hTurnoverUSDT, setMinimum24hTurnoverUSDT] = useState(10_000_000)
  const [sort, setSort] = useState<SortKey>("momentum")
  const [descending, setDescending] = useState(true)
  useEffect(() => {
    let stopped = false
    let timer: number
    const refresh = async () => {
      try {
        const snapshot = await window.webkit.messageHandlers.radar.postMessage({ rocPeriod: ROC_PERIOD, marocPeriod: MAROC_PERIOD })
        if (stopped) return
        setRows(snapshot.rows)
        setMinimum24hTurnoverUSDT(snapshot.minimum24hTurnoverUSDT)
        setUpdatedAt(snapshot.updatedAt)
        setStatus("Live")
        setError(snapshot.error)
      } catch (cause) {
        if (stopped) return
        setStatus("Reconnecting")
        setError(cause instanceof Error ? cause.message : "Cannot connect to the native collector")
      }
      if (!stopped) timer = window.setTimeout(refresh, 2000)
    }
    void refresh()
    return () => { stopped = true; window.clearTimeout(timer) }
  }, [])

  useEffect(() => {
    const table = document.querySelector("table")
    if (!table) return
    const fit = () => { void window.webkit.messageHandlers.radar.postMessage({ fitWidth: Math.ceil(table.scrollWidth) }).catch(() => {}) }
    const observer = new ResizeObserver(fit)
    observer.observe(table)
    void document.fonts.ready.then(fit)
    return () => observer.disconnect()
  }, [])

  const visible = useMemo(() => {
    const scores = momentumScores(rows)
    return rows.map((row, index) => ({ ...row, momentum: scores[index], trend: marketTrend(row) }))
      .filter(row => matchesMarketFilter(row, trapOnly))
      .filter(row => row.instId.toLowerCase().includes(query.trim().toLowerCase()))
      .sort((a, b) => compareMarketRows(a, b, sort, descending))
  }, [rows, query, sort, descending, trapOnly])

  const changeSort = (key: SortKey) => {
    if (sort === key) setDescending(!descending)
    else { setSort(key); setDescending(key !== "instId") }
  }

  const changeTurnoverThreshold = (value: string) => {
    if (!value) return
    void window.webkit.messageHandlers.radar.postMessage({ minimum24hTurnoverUSDT: Number(value) })
      .then(snapshot => {
        setMinimum24hTurnoverUSDT(snapshot.minimum24hTurnoverUSDT)
        setRows(snapshot.rows)
        setUpdatedAt(snapshot.updatedAt)
        setError(snapshot.error)
      })
      .catch(cause => setError(cause instanceof Error ? cause.message : "Cannot save turnover setting"))
  }

  const header = (label: string, key: SortKey, formula: string) => {
    const SortIcon = sort !== key ? ArrowDownUp : descending ? ArrowDown : ArrowUp
    return <Button variant="ghost" size="sm" className="h-auto min-h-6 gap-1" onClick={() => changeSort(key)} aria-label={`Sort by ${label}`}>
      {math(formula)}<SortIcon data-icon="inline-end" aria-hidden="true" />
    </Button>
  }

  return (
    <main className="flex min-h-svh flex-col">
      <header className="flex flex-wrap items-center gap-3 border-b px-4 py-3">
        <h1 className="text-base font-semibold tracking-tight">Perpetual Radar</h1>
        <span className="text-xs text-muted-foreground">OKX · USDT swaps · 1h · 24h turnover ≥ {minimum24hTurnoverUSDT / 1_000_000}M USDT</span>
        <span className="text-xs tabular-nums text-muted-foreground">{visible.length} / {rows.length} markets</span>
        <Button variant={trapOnly ? "secondary" : "outline"} size="sm" aria-pressed={trapOnly} onClick={() => setTrapOnly(!trapOnly)}>Only TRAP</Button>
        <Popover>
          <PopoverTrigger asChild><Button variant="outline" size="sm"><Settings2 data-icon="inline-start" aria-hidden="true" />Settings</Button></PopoverTrigger>
          <PopoverContent align="end">
            <PopoverHeader>
              <PopoverTitle>Settings</PopoverTitle>
              <PopoverDescription>Hide swaps below the selected 24h USDT turnover.</PopoverDescription>
            </PopoverHeader>
            <FieldGroup>
              <Field>
                <FieldTitle id="turnover-threshold-label">Minimum 24h turnover</FieldTitle>
                <ToggleGroup type="single" variant="outline" size="sm" spacing={0} value={String(minimum24hTurnoverUSDT)} onValueChange={changeTurnoverThreshold} aria-labelledby="turnover-threshold-label">
                  <ToggleGroupItem value="10000000" aria-label="10 million USDT">10M</ToggleGroupItem>
                  <ToggleGroupItem value="30000000" aria-label="30 million USDT">30M</ToggleGroupItem>
                  <ToggleGroupItem value="100000000" aria-label="100 million USDT">100M</ToggleGroupItem>
                </ToggleGroup>
              </Field>
            </FieldGroup>
          </PopoverContent>
        </Popover>
        <div className="relative min-w-48 flex-1 sm:ml-auto sm:max-w-64">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
          <Input aria-label="Search contracts" placeholder="Search contracts" value={query} onChange={event => setQuery(event.target.value)} className="pl-8" />
        </div>
        <Badge variant={status === "Live" ? "secondary" : "outline"} aria-live="polite">
          <Radio aria-hidden="true" />{status}
        </Badge>
        <span className="text-xs text-muted-foreground">{updatedAt ? `Updated ${new Date(updatedAt).toLocaleTimeString("en-US")}` : "Waiting for data"}</span>
      </header>
      {error && <p role="alert" className="border-b px-4 py-2 text-sm text-destructive">{error}</p>}
      <section aria-label="Perpetual swap markets" className="flex-1">
        <Table className="table-auto">
          <TableHeader>
            <TableRow className="bg-muted/30">
              <TableHead className="text-center" aria-sort={sort === "instId" ? descending ? "descending" : "ascending" : "none"}>{header("Symbol", "instId", String.raw`\operatorname{Symbol}`)}</TableHead>
              <TableHead className="text-center" aria-sort={sort === "momentum" ? descending ? "descending" : "ascending" : "none"} title="Equal-weighted price momentum (mean rank of |ROC| and |MAROC|), positive OI log change, and positive volume log change">{header("Momentum", "momentum", String.raw`\operatorname{Momentum}`)}</TableHead>
              <TableHead className="text-center" title="LONG: price above VWAP14, EMA200 and BOLL middle, with Taker Buy above Sell. SHORT: all four reversed. Otherwise TRAP.">{math(String.raw`\operatorname{Trend}`)}</TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort === "high48" || sort === "low48" ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {header("48h high", "high48", String.raw`\operatorname{High}_{48}=\max(H_{t-48},\ldots,H_{t-1})`)}
                  {header("48h low", "low48", String.raw`\operatorname{Low}_{48}=\min(L_{t-48},\ldots,L_{t-1})`)}
                </div>
              </TableHead>
              <TableHead className="text-center" aria-sort={sort === "oiLog" ? descending ? "descending" : "ascending" : "none"}>{header("OI log change", "oiLog", String.raw`\ln\left(\frac{OI_t}{OI_{t-1}}\right)`)}</TableHead>
              <TableHead className="text-center" aria-sort={sort === "takerRatio" ? descending ? "descending" : "ascending" : "none"}>{header("Taker buy-sell ratio", "takerRatio", String.raw`\frac{Buy_t-Sell_t}{Buy_t+Sell_t}\times100\%`)}</TableHead>
              <TableHead className="text-center" aria-sort={sort === "volumeLog" ? descending ? "descending" : "ascending" : "none"}>{header("Volume Log Change", "volumeLog", String.raw`\ln\left(\frac{V_t}{V_{t-1}}\right)`)}</TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort === "roc" || sort === "maroc" ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {header(`ROC ${ROC_PERIOD}`, "roc", String.raw`\operatorname{ROC}_{${ROC_PERIOD}}`)}
                  {header(`MAROC ${MAROC_PERIOD}`, "maroc", String.raw`\operatorname{MAROC}_{${MAROC_PERIOD}}`)}
                </div>
              </TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort.startsWith("rsi") ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {RSI_PERIODS.map(period => <Fragment key={period}>{header(`RSI ${period}`, `rsi${period}`, String.raw`\operatorname{RSI}_{${period}}`)}</Fragment>)}
                </div>
              </TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort.startsWith("boll") ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {BOLL_LINES.map(({ label, key }) => <Fragment key={key}>{header(`BOLL ${label}`, key, String.raw`\operatorname{BOLL}_{\mathrm{${label}}}`)}</Fragment>)}
                </div>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {visible.length ? visible.map(row => <TableRow key={row.instId} className="hover:bg-accent/50">
              <TableCell className="text-center" title={row.instId}>
                <a className="font-medium underline-offset-4 hover:underline focus-visible:underline" href={`https://www.okx.com/trade-swap/${encodeURIComponent(row.instId.toLowerCase())}`} target="_blank" rel="noopener noreferrer" aria-label={`View ${row.instId} chart on OKX (opens in a new tab)`}>{row.instId.replace(/-USDT-SWAP$/, "")}</a>
                <div className="flex justify-center gap-2 text-xs tabular-nums">
                  <span>{formatPrice(row.price)}</span>
                  <span className={directionClass(row.priceChange)}>{formatPercent(row.priceChange)}</span>
                </div>
                <div className="flex justify-center gap-1 text-xs tabular-nums">
                  <span className="text-muted-foreground">VWAP14</span><span>{formatPrice(row.vwap14)}</span>
                </div>
                <div className="flex justify-center gap-1 text-xs tabular-nums">
                  <span className="text-muted-foreground">EMA200</span>
                  <span className={directionClass(row.ema200Slope)}>{formatPrice(row.ema200)}{row.ema200Slope !== null && <span className="sr-only"> {row.ema200Slope > 0 ? "rising" : row.ema200Slope < 0 ? "falling" : "flat"}</span>}</span>
                </div>
              </TableCell>
              <TableCell className="text-center tabular-nums" title="Score from 0 to 100 across markets with complete data">{formatIndicator(row.momentum)}</TableCell>
              <TableCell className={cn("text-center font-medium", row.trend === "LONG" ? "text-positive" : row.trend === "SHORT" ? "text-destructive" : "text-muted-foreground")}>{row.trend ?? "—"}</TableCell>
              <TableCell className="text-center tabular-nums">
                <div className="mx-auto grid w-max grid-cols-[max-content_max-content] gap-x-3 text-right">
                  <span><span className="sr-only">48h high </span>{formatPrice(row.high48)}</span>
                  <span className={directionClass(row.high48Diff)}><span className="sr-only">current price versus high </span>{formatPercent(row.high48Diff)}</span>
                  <span><span className="sr-only">48h low </span>{formatPrice(row.low48)}</span>
                  <span className={directionClass(row.low48Diff)}><span className="sr-only">current price versus low </span>{formatPercent(row.low48Diff)}</span>
                </div>
              </TableCell>
              <TableCell className={cn("text-center tabular-nums", directionClass(row.oiLog))} title={row.oi !== null && row.oiBase !== null ? `Current OI ${row.oi.toLocaleString("en-US")} / previous hour close ${row.oiBase.toLocaleString("en-US")}` : "Loading hourly OI history"}>{formatLog(row.oiLog)}</TableCell>
              <TableCell className={cn("text-center tabular-nums", directionClass(row.takerRatio))} title={row.buy !== null && row.sell !== null ? `Buy ${row.buy.toLocaleString("en-US")} / Sell ${row.sell.toLocaleString("en-US")} contracts` : "Loading current-hour taker volume"}>{formatPercent(row.takerRatio)}</TableCell>
              <TableCell className={cn("text-center tabular-nums", directionClass(row.volumeLog))}>{formatLog(row.volumeLog)}</TableCell>
              <TableCell className="text-center tabular-nums">
                <div className="mx-auto grid w-max grid-cols-[max-content_max-content] gap-x-3 text-right">
                  <span className={directionClass(row.roc)}><span className="sr-only">ROC </span>{formatIndicator(row.roc)}</span>
                  <span className={directionClass(row.rocChange)}><span className="sr-only">ROC hourly change </span>{formatPercent(row.rocChange)}</span>
                  <span className={directionClass(row.maroc)}><span className="sr-only">MAROC </span>{formatIndicator(row.maroc)}</span>
                  <span className={directionClass(row.marocChange)}><span className="sr-only">MAROC hourly change </span>{formatPercent(row.marocChange)}</span>
                </div>
              </TableCell>
              <TableCell className="text-center tabular-nums">
                <div className="flex flex-col items-center text-xs">
                  {RSI_PERIODS.map(period => <div key={period} className="flex gap-1"><span className="text-muted-foreground">{period}</span><span className={rsiClass(row[`rsi${period}`])}>{formatIndicator(row[`rsi${period}`])}</span></div>)}
                </div>
              </TableCell>
              <TableCell className="text-center tabular-nums">
                <div className="flex flex-col items-center text-xs">
                  {BOLL_LINES.map(({ label, key }) => <div key={key} className="flex gap-1"><span className="text-muted-foreground">{label}</span><span className={bollClass(row.price, row[key])}>{formatPrice(row[key])}</span></div>)}
                </div>
              </TableCell>
            </TableRow>) : <TableRow><TableCell colSpan={10} className="py-16 text-center text-muted-foreground">{rows.length ? query.trim() ? "No matching contracts" : trapOnly ? "No TRAP contracts" : "No contracts pass the ROC/MAROC and Trend filters" : "Loading OKX contracts…"}</TableCell></TableRow>}
          </TableBody>
        </Table>
      </section>
    </main>
  )
}

export default App
