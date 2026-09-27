import { useEffect, useState } from "react"
import { ArrowLeft, Radio } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"

type Bar = {
  hour: number; open: number; high: number; low: number; close: number; volume: number; confirmed: boolean
  vwap: number | null; ema: number | null; bollUpper: number | null; bollMiddle: number | null; bollLower: number | null
  roc: number | null; maroc: number | null; rsi6: number | null; rsi12: number | null; rsi24: number | null
  oi: number | null; buy: number | null; sell: number | null
}
export type ChartResponse = { bars: Bar[]; error: string }

const left = 78, right = 1100, plotWidth = right - left
const panels = { price: [34, 302], volume: [306, 356], rsi: [385, 467], roc: [496, 570], oi: [600, 660], taker: [690, 750] } as const
const compact = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("en-US", { maximumSignificantDigits: 5, notation: "compact" }).format(value)
const price = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("en-US", { maximumSignificantDigits: 8 }).format(value)
const time = (hour: number) => new Date(hour).toLocaleString("en-US", { month: "2-digit", day: "2-digit", hour: "2-digit", hour12: false })

function Plot({ bars, hovered }: { bars: Bar[]; hovered: number | null }) {
  const n = bars.length
  const x = (index: number) => left + (index + 0.5) * plotWidth / n
  const barWidth = Math.max(4, Math.min(14, plotWidth / n * 0.58))
  const priceValues = bars.flatMap(bar => [bar.low, bar.high, bar.vwap, bar.ema, bar.bollUpper, bar.bollLower].filter((value): value is number => value !== null))
  const priceMin = Math.min(...priceValues), priceMax = Math.max(...priceValues)
  const rocValues = bars.flatMap(bar => [bar.roc, bar.maroc].filter((value): value is number => value !== null))
  const rocExtent = Math.max(0.1, ...rocValues.map(Math.abs)) * 1.15
  const oiValues = bars.flatMap(bar => bar.oi === null ? [] : [bar.oi])
  const oiMin = Math.min(...oiValues), oiMax = Math.max(...oiValues)
  const maxVolume = Math.max(1, ...bars.map(bar => bar.volume))
  const maxTaker = Math.max(1, ...bars.map(bar => (bar.buy ?? 0) + (bar.sell ?? 0)))
  const scale = (value: number, min: number, max: number, panel: readonly [number, number]) =>
    panel[1] - (value - min) / (max - min || 1) * (panel[1] - panel[0])
  const priceY = (value: number) => scale(value, priceMin - (priceMax - priceMin) * 0.05, priceMax + (priceMax - priceMin) * 0.05, panels.price)
  const line = (key: keyof Bar, panel: readonly [number, number], min: number, max: number) => {
    const segments: string[] = []
    let segment = ""
    bars.forEach((bar, index) => {
      const value = bar[key]
      if (typeof value !== "number") { if (segment) segments.push(segment); segment = ""; return }
      segment += `${segment ? " L" : "M"}${x(index).toFixed(1)} ${scale(value, min, max, panel).toFixed(1)}`
    })
    if (segment) segments.push(segment)
    return segments.join(" ")
  }
  const priceLine = (key: keyof Bar) => {
    const segments: string[] = []
    let segment = ""
    bars.forEach((bar, index) => {
      const value = bar[key]
      if (typeof value !== "number") { if (segment) segments.push(segment); segment = ""; return }
      segment += `${segment ? " L" : "M"}${x(index).toFixed(1)} ${priceY(value).toFixed(1)}`
    })
    if (segment) segments.push(segment)
    return segments.join(" ")
  }
  const lineStroke = (d: string, color: string, width = 1.5) => <path d={d} fill="none" stroke={color} strokeWidth={width} strokeLinejoin="round" />
  const grid = Object.values(panels).flatMap(([top, bottom]) => [top, bottom]).map((y, index) =>
    <line key={index} x1={left} x2={right} y1={y} y2={y} stroke="var(--border)" strokeWidth="1" />)
  const labels = [
    ["PRICE · VWAP14 · EMA200 · BOLL20", panels.price[0] + 13],
    ["VOLUME · USDT", panels.volume[0] + 13],
    ["RSI 6 / 12 / 24", panels.rsi[0] + 13],
    ["ROC9 / MAROC9 · %", panels.roc[0] + 13],
    ["OPEN INTEREST · USD", panels.oi[0] + 13],
    ["TAKER BUY / SELL", panels.taker[0] + 13],
  ] as const
  return <>
    {grid}
    {bars.filter((_, index) => index % 6 === 0).map(bar => {
      const index = bars.indexOf(bar)
      return <g key={bar.hour}><line x1={x(index)} x2={x(index)} y1={panels.price[0]} y2={panels.taker[1]} stroke="var(--border)" strokeOpacity="0.5" /><text x={x(index)} y="777" textAnchor="middle" fill="var(--muted-foreground)" fontSize="11">{time(bar.hour)}</text></g>
    })}
    {labels.map(([label, y]) => <text key={label} x="12" y={y} fill="var(--muted-foreground)" fontSize="10" fontWeight="600">{label}</text>)}
    {[0.25, 0.5, 0.75].map(fraction => <g key={fraction}><line x1={left} x2={right} y1={panels.price[0] + fraction * (panels.price[1] - panels.price[0])} y2={panels.price[0] + fraction * (panels.price[1] - panels.price[0])} stroke="var(--border)" strokeOpacity="0.5" /><text x={right + 8} y={panels.price[0] + fraction * (panels.price[1] - panels.price[0]) + 4} fill="var(--muted-foreground)" fontSize="11">{price(priceMax - fraction * (priceMax - priceMin))}</text></g>)}
    {bars.map((bar, index) => {
      const up = bar.close >= bar.open
      const color = up ? "var(--positive)" : "var(--destructive)"
      const y1 = priceY(Math.max(bar.open, bar.close)), y2 = priceY(Math.min(bar.open, bar.close))
      const volHeight = bar.volume / maxVolume * (panels.volume[1] - panels.volume[0])
      const buyHeight = (bar.buy ?? 0) / maxTaker * (panels.taker[1] - panels.taker[0])
      const sellHeight = (bar.sell ?? 0) / maxTaker * (panels.taker[1] - panels.taker[0])
      return <g key={bar.hour}>
        <line x1={x(index)} x2={x(index)} y1={priceY(bar.high)} y2={priceY(bar.low)} stroke={color} strokeWidth="1.5" />
        <rect x={x(index) - barWidth / 2} y={y1} width={barWidth} height={Math.max(1.5, y2 - y1)} fill={color} />
        <rect x={x(index) - barWidth / 2} y={panels.volume[1] - volHeight} width={barWidth} height={volHeight} fill={color} opacity="0.65" />
        <rect x={x(index) - barWidth / 2} y={panels.taker[1] - buyHeight} width={barWidth} height={buyHeight} fill="var(--positive)" opacity="0.75" />
        <rect x={x(index) - barWidth / 2} y={panels.taker[1] - buyHeight - sellHeight} width={barWidth} height={sellHeight} fill="var(--destructive)" opacity="0.75" />
      </g>
    })}
    {lineStroke(priceLine("bollUpper"), "var(--chart-1)", 1)}
    {lineStroke(priceLine("bollLower"), "var(--chart-1)", 1)}
    {lineStroke(priceLine("bollMiddle"), "var(--chart-1)", 1)}
    {lineStroke(priceLine("vwap"), "var(--chart-2)", 2)}
    {lineStroke(priceLine("ema"), "var(--chart-3)", 2)}
    {[30, 70].map(value => <line key={value} x1={left} x2={right} y1={scale(value, 0, 100, panels.rsi)} y2={scale(value, 0, 100, panels.rsi)} stroke="var(--muted-foreground)" strokeDasharray="4 4" opacity="0.55" />)}
    {lineStroke(line("rsi6", panels.rsi, 0, 100), "var(--chart-1)")}
    {lineStroke(line("rsi12", panels.rsi, 0, 100), "var(--chart-2)")}
    {lineStroke(line("rsi24", panels.rsi, 0, 100), "var(--chart-3)")}
    <line x1={left} x2={right} y1={scale(0, -rocExtent, rocExtent, panels.roc)} y2={scale(0, -rocExtent, rocExtent, panels.roc)} stroke="var(--muted-foreground)" strokeDasharray="4 4" opacity="0.55" />
    {lineStroke(line("roc", panels.roc, -rocExtent, rocExtent), "var(--chart-1)")}
    {lineStroke(line("maroc", panels.roc, -rocExtent, rocExtent), "var(--chart-3)")}
    {oiValues.length > 0 && lineStroke(line("oi", panels.oi, oiMin * 0.99, oiMax * 1.01), "var(--chart-2)", 2)}
    {hovered !== null && <line x1={x(hovered)} x2={x(hovered)} y1={panels.price[0]} y2={panels.taker[1]} stroke="var(--foreground)" strokeDasharray="3 3" opacity="0.7" />}
    <text x={right + 8} y={panels.rsi[0] + 14} fill="var(--muted-foreground)" fontSize="11">100</text>
    <text x={right + 8} y={panels.rsi[1]} fill="var(--muted-foreground)" fontSize="11">0</text>
    <text x={right + 8} y={panels.roc[0] + 14} fill="var(--muted-foreground)" fontSize="11">+{rocExtent.toFixed(1)}</text>
    <text x={right + 8} y={panels.roc[1]} fill="var(--muted-foreground)" fontSize="11">-{rocExtent.toFixed(1)}</text>
    <text x={right + 8} y={panels.oi[0] + 14} fill="var(--muted-foreground)" fontSize="11">{compact(oiMax)}</text>
    <text x={right + 8} y={panels.oi[1]} fill="var(--muted-foreground)" fontSize="11">{compact(oiMin)}</text>
  </>
}

export function MarketChart({ instId, onBack }: { instId: string; onBack: () => void }) {
  const [chart, setChart] = useState<ChartResponse | null>(null)
  const [hovered, setHovered] = useState<number | null>(null)
  const [error, setError] = useState("")
  useEffect(() => {
    let stopped = false
    let timer: number
    let lastLoad = 0
    const refresh = async () => {
      try {
        const loadChart = Date.now() - lastLoad >= 60_000
        const result = await window.webkit.messageHandlers.radar.postMessage({ chartInstId: instId, loadChart })
        if (stopped) return
        if (loadChart) lastLoad = Date.now()
        setChart(result)
        setError(result.error)
      } catch (cause) {
        if (!stopped) setError(cause instanceof Error ? cause.message : "Cannot load chart")
      }
      if (!stopped) timer = window.setTimeout(refresh, 2000)
    }
    void refresh()
    return () => { stopped = true; window.clearTimeout(timer) }
  }, [instId])

  const bars = chart?.bars ?? []
  const active = bars[hovered ?? bars.length - 1]
  return <main className="flex min-h-svh flex-col">
    <header className="flex flex-wrap items-center gap-3 border-b px-4 py-3">
      <Button variant="outline" size="sm" onClick={onBack}><ArrowLeft data-icon="inline-start" aria-hidden="true" />Markets</Button>
      <h1 className="text-base font-semibold tracking-tight">{instId.replace(/-SWAP$/, "")} · 1h</h1>
      <Badge variant="secondary"><Radio aria-hidden="true" />Live chart</Badge>
      <span className="text-xs text-muted-foreground">Latest 48 hourly candles · OKX</span>
    </header>
    {error && <p role="alert" className="border-b px-4 py-2 text-sm text-destructive">{error}</p>}
    <section aria-label={`${instId} chart`} className="flex-1 px-4 py-3">
      {active && <div className="mb-3 flex flex-wrap gap-x-5 gap-y-1 text-xs tabular-nums" aria-live="off">
        <span className="font-medium">{time(active.hour)}{active.confirmed ? "" : " · live"}</span>
        <span>O {price(active.open)} · H {price(active.high)} · L {price(active.low)} · C {price(active.close)}</span>
        <span>VWAP14 {price(active.vwap)} · EMA200 {price(active.ema)}</span>
        <span>OI {compact(active.oi)} USD · Taker buy {compact(active.buy)} / sell {compact(active.sell)}</span>
        <span>ROC {active.roc?.toFixed(2) ?? "—"} · MAROC {active.maroc?.toFixed(2) ?? "—"} · RSI 6/12/24 {active.rsi6?.toFixed(1) ?? "—"}/{active.rsi12?.toFixed(1) ?? "—"}/{active.rsi24?.toFixed(1) ?? "—"}</span>
      </div>}
      {bars.length ? <div className="overflow-x-auto rounded-lg border bg-card p-2">
        <svg viewBox="0 0 1200 790" className="min-w-[950px] w-full" role="img" aria-label={`${instId} 48 hour candlestick chart with VWAP14, EMA200, Bollinger bands, volume, RSI, ROC, MAROC, open interest and taker volume`} onPointerLeave={() => setHovered(null)} onPointerMove={event => {
          const rect = event.currentTarget.getBoundingClientRect()
          const svgX = (event.clientX - rect.left) * 1200 / rect.width
          setHovered(Math.max(0, Math.min(bars.length - 1, Math.floor((svgX - left) / plotWidth * bars.length))))
        }}>
          <Plot bars={bars} hovered={hovered} />
        </svg>
      </div> : <p className="py-20 text-center text-sm text-muted-foreground">{chart ? "No candle data available yet" : "Loading chart…"}</p>}
    </section>
  </main>
}
