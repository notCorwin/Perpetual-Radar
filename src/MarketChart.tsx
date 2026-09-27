import { useEffect, useRef, useState } from "react"
import { ArrowLeft, Radio } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"

type Bar = {
  hour: number; open: number; high: number; low: number; close: number; confirmed: boolean
  vwap: number | null; ema: number | null; bollUpper: number | null; bollMiddle: number | null; bollLower: number | null
  roc: number | null; maroc: number | null; rsi6: number | null; rsi12: number | null; rsi24: number | null
  oi: number | null; buy: number | null; sell: number | null
}
export type ChartResponse = { bars: Bar[]; error: string; revision: number }
export type ChartPollResponse = ChartResponse | { unchanged: true; error: string; revision: number }

const left = 16
const compact = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("en-US", { maximumSignificantDigits: 5, notation: "compact" }).format(value)
const price = (value: number | null) => value === null ? "—" : new Intl.NumberFormat("en-US", { maximumSignificantDigits: 8 }).format(value)
const time = (hour: number) => new Date(hour).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false })
const hourLabel = (hour: number) => new Date(hour).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", hour12: false })
type Panel = "price" | "rsi" | "roc" | "oi" | "taker"
const chartLayout = (width: number, height: number) => {
  const right = width - 16, middle = width / 2
  const plotHeight = Math.max(1, height - 32 - 22 - 72)
  const priceBottom = 32 + plotHeight * 0.55
  const lowerHeight = plotHeight * 0.45 / 2
  const firstRow = priceBottom + 36, secondRow = firstRow + lowerHeight + 36
  const panels: Record<Panel, readonly [number, number]> = {
    price: [32, priceBottom], rsi: [firstRow, firstRow + lowerHeight], roc: [firstRow, firstRow + lowerHeight],
    oi: [secondRow, secondRow + lowerHeight], taker: [secondRow, secondRow + lowerHeight],
  }
  const columns: Record<Panel, readonly [number, number]> = {
    price: [left, right], rsi: [left, middle - 16], roc: [middle + 16, right],
    oi: [left, middle - 16], taker: [middle + 16, right],
  }
  return { panels, columns, right }
}

function Plot({ bars, hovered, width, height }: { bars: Bar[]; hovered: number | null; width: number; height: number }) {
  const n = bars.length
  const active = bars[hovered ?? n - 1]
  const { panels, columns, right } = chartLayout(width, height)
  const x = (index: number, panel: Panel) => columns[panel][0] + (index + 0.5) * (columns[panel][1] - columns[panel][0]) / n
  const barWidth = Math.max(5, Math.min(14, (right - left) / n * 0.75))
  const takerBarWidth = Math.max(2, Math.min(9, (columns.taker[1] - columns.taker[0]) / n * 0.7))
  const priceValues = bars.flatMap(bar => [bar.low, bar.high, bar.vwap, bar.ema, bar.bollUpper, bar.bollLower].filter((value): value is number => value !== null))
  const priceMin = Math.min(...priceValues), priceMax = Math.max(...priceValues)
  const axisPrice = new Intl.NumberFormat("en-US", { maximumFractionDigits: Math.min(12, Math.max(2, Math.ceil(-Math.log10((priceMax - priceMin) / 4 || 1)))) })
  const rocValues = bars.flatMap(bar => [bar.roc, bar.maroc].filter((value): value is number => value !== null))
  const rocExtent = Math.max(0.1, ...rocValues.map(Math.abs)) * 1.15
  const oiValues = bars.flatMap(bar => bar.oi === null ? [] : [bar.oi])
  const oiMin = Math.min(...oiValues), oiMax = Math.max(...oiValues)
  const maxTaker = Math.max(1, ...bars.map(bar => (bar.buy ?? 0) + (bar.sell ?? 0)))
  const scale = (value: number, min: number, max: number, panel: readonly [number, number]) =>
    panel[1] - (value - min) / (max - min || 1) * (panel[1] - panel[0])
  const priceY = (value: number) => scale(value, priceMin - (priceMax - priceMin) * 0.05, priceMax + (priceMax - priceMin) * 0.05, panels.price)
  const latest = bars[n - 1]
  const latestY = priceY(latest.close)
  const latestColor = latest.close >= latest.open ? "var(--positive)" : "var(--destructive)"
  const line = (key: keyof Bar, panelKey: Panel, min: number, max: number) => {
    const segments: string[] = []
    let segment = ""
    bars.forEach((bar, index) => {
      const value = bar[key]
      if (typeof value !== "number") { if (segment) segments.push(segment); segment = ""; return }
      segment += `${segment ? " L" : "M"}${x(index, panelKey).toFixed(1)} ${scale(value, min, max, panels[panelKey]).toFixed(1)}`
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
      segment += `${segment ? " L" : "M"}${x(index, "price").toFixed(1)} ${priceY(value).toFixed(1)}`
    })
    if (segment) segments.push(segment)
    return segments.join(" ")
  }
  const bollBands: string[] = []
  let upper: string[] = [], lower: string[] = []
  const finishBand = () => {
    if (upper.length > 1) bollBands.push(`M${upper.join(" L")} L${lower.reverse().join(" L")} Z`)
    upper = []; lower = []
  }
  bars.forEach((bar, index) => {
    if (bar.bollUpper === null || bar.bollLower === null) { finishBand(); return }
    const pointX = x(index, "price").toFixed(1)
    upper.push(`${pointX} ${priceY(bar.bollUpper).toFixed(1)}`)
    lower.push(`${pointX} ${priceY(bar.bollLower).toFixed(1)}`)
  })
  finishBand()
  const lineStroke = (d: string, color: string, width = 1.5) => <path d={d} fill="none" stroke={color} strokeWidth={width} strokeLinejoin="round" />
  const axisLabel = (x: number, y: number, label: string, color = "var(--muted-foreground)", bold = false) =>
    <text x={x - 4} y={y} textAnchor="end" dominantBaseline="middle" fill={color} fontSize="11" fontWeight={bold ? "600" : undefined} stroke="var(--card)" strokeWidth="5" strokeLinejoin="round" paintOrder="stroke">{label}</text>
  const panelKeys: Panel[] = ["price", "rsi", "roc", "oi", "taker"]
  const grid = panelKeys.flatMap(key => panels[key].map((y, index) =>
    <line key={`${key}-${index}`} x1={columns[key][0]} x2={columns[key][1]} y1={y} y2={y} stroke="var(--border)" strokeWidth="1" />))
  const legendStart: Record<Panel, number> = { price: 165, rsi: columns.rsi[0] + 90, roc: columns.roc[0] + 80, oi: columns.oi[0] + 160, taker: columns.taker[0] + 120 }
  const legendStep: Record<Panel, number> = { price: 205, rsi: 90, roc: 145, oi: 120, taker: 120 }
  const legend = (key: Panel, title: string, items: [string, string, string][]) => <g key={title}>
    <text x={columns[key][0]} y={panels[key][0] - 14} fill="var(--foreground)" fontSize="11" fontWeight="650">{title}</text>
    {items.map(([label, value, color], index) => <g key={label} transform={`translate(${legendStart[key] + index * legendStep[key]},${panels[key][0] - 14})`}>
      <line x1="0" x2="13" y1="-4" y2="-4" stroke={color} strokeWidth="2.5" />
      <text x="19" fill="var(--muted-foreground)" fontSize="11">{label} <tspan fill="var(--foreground)" fontWeight="600">{value}</tspan></text>
    </g>)}
  </g>
  return <>
    {bollBands.map((d, index) => <path key={index} d={d} fill="var(--chart-1)" fillOpacity="0.13" />)}
    <rect x={columns.rsi[0]} y={scale(70, 0, 100, panels.rsi)} width={columns.rsi[1] - columns.rsi[0]} height={scale(30, 0, 100, panels.rsi) - scale(70, 0, 100, panels.rsi)} fill="var(--chart-2)" fillOpacity="0.08" />
    {grid}
    {bars.map((bar, index) => index % 12 === 0 && <line key={bar.hour} x1={x(index, "price")} x2={x(index, "price")} y1={panels.price[0]} y2={panels.price[1]} stroke="var(--border)" strokeOpacity="0.35" />)}
    {(["rsi", "roc", "oi", "taker"] as const).flatMap(key => [0, Math.floor(n / 2)].map(index => <line key={`${key}-${index}`} x1={x(index, key)} x2={x(index, key)} y1={panels[key][0]} y2={panels[key][1]} stroke="var(--border)" strokeOpacity="0.35" />))}
    {(["oi", "taker"] as const).flatMap(key => [0, Math.floor(n / 2), n - 1].map(index => <text key={`${key}-${index}`} x={index === 0 ? columns[key][0] : index === n - 1 ? columns[key][1] : x(index, key)} y={height - 8} textAnchor={index === 0 ? "start" : index === n - 1 ? "end" : "middle"} fill="var(--muted-foreground)" fontSize="11">{hourLabel(bars[index].hour)}</text>))}
    {[0.25, 0.5, 0.75].map(fraction => {
      const tickY = panels.price[0] + fraction * (panels.price[1] - panels.price[0])
      return <g key={fraction}><line x1={left} x2={right} y1={tickY} y2={tickY} stroke="var(--border)" strokeOpacity="0.55" />{Math.abs(tickY - latestY) > 14 && axisLabel(right, tickY, axisPrice.format(priceMax - fraction * (priceMax - priceMin)))}</g>
    })}
    <line x1={left} x2={right} y1={latestY} y2={latestY} stroke={latestColor} strokeDasharray="2 3" opacity="0.65" />
    {bars.map((bar, index) => {
      const up = bar.close >= bar.open
      const color = up ? "var(--positive)" : "var(--destructive)"
      const y1 = priceY(Math.max(bar.open, bar.close)), y2 = priceY(Math.min(bar.open, bar.close))
      const buyHeight = (bar.buy ?? 0) / maxTaker * (panels.taker[1] - panels.taker[0])
      const sellHeight = (bar.sell ?? 0) / maxTaker * (panels.taker[1] - panels.taker[0])
      return <g key={bar.hour}>
        <line x1={x(index, "price")} x2={x(index, "price")} y1={priceY(bar.high)} y2={priceY(bar.low)} stroke={color} strokeWidth="1.5" />
        <rect x={x(index, "price") - barWidth / 2} y={y1} width={barWidth} height={Math.max(1.5, y2 - y1)} fill={color} />
        <rect x={x(index, "taker") - takerBarWidth / 2} y={panels.taker[1] - buyHeight} width={takerBarWidth} height={buyHeight} fill="var(--positive)" opacity="0.75" />
        <rect x={x(index, "taker") - takerBarWidth / 2} y={panels.taker[1] - buyHeight - sellHeight} width={takerBarWidth} height={sellHeight} fill="var(--destructive)" opacity="0.75" />
      </g>
    })}
    {lineStroke(priceLine("bollUpper"), "var(--chart-1)", 1)}
    {lineStroke(priceLine("bollLower"), "var(--chart-1)", 1)}
    {lineStroke(priceLine("bollMiddle"), "var(--chart-1)", 1)}
    {lineStroke(priceLine("vwap"), "var(--chart-2)", 2)}
    {lineStroke(priceLine("ema"), "var(--chart-3)", 2)}
    {[30, 70].map(value => <line key={value} x1={columns.rsi[0]} x2={columns.rsi[1]} y1={scale(value, 0, 100, panels.rsi)} y2={scale(value, 0, 100, panels.rsi)} stroke="var(--muted-foreground)" strokeDasharray="4 4" opacity="0.55" />)}
    {lineStroke(line("rsi6", "rsi", 0, 100), "var(--chart-1)")}
    {lineStroke(line("rsi12", "rsi", 0, 100), "var(--chart-2)")}
    {lineStroke(line("rsi24", "rsi", 0, 100), "var(--chart-3)")}
    <line x1={columns.roc[0]} x2={columns.roc[1]} y1={scale(0, -rocExtent, rocExtent, panels.roc)} y2={scale(0, -rocExtent, rocExtent, panels.roc)} stroke="var(--muted-foreground)" strokeDasharray="4 4" opacity="0.55" />
    {lineStroke(line("roc", "roc", -rocExtent, rocExtent), "var(--chart-1)")}
    {lineStroke(line("maroc", "roc", -rocExtent, rocExtent), "var(--chart-3)")}
    {oiValues.length > 0 && lineStroke(line("oi", "oi", oiMin * 0.99, oiMax * 1.01), "var(--chart-2)", 2)}
    {hovered !== null && panelKeys.map(key => <line key={key} x1={x(hovered, key)} x2={x(hovered, key)} y1={panels[key][0]} y2={panels[key][1]} stroke="var(--foreground)" strokeDasharray="3 3" opacity="0.7" />)}
    {axisLabel(right, latestY, price(latest.close), latestColor, true)}
    {legend("price", "PRICE · USDT", [["VWAP14", price(active.vwap), "var(--chart-2)"], ["EMA200", price(active.ema), "var(--chart-3)"], ["BOLL20", price(active.bollMiddle), "var(--chart-1)"]])}
    {legend("rsi", "RSI · 30–70", [["6", active.rsi6?.toFixed(1) ?? "—", "var(--chart-1)"], ["12", active.rsi12?.toFixed(1) ?? "—", "var(--chart-2)"], ["24", active.rsi24?.toFixed(1) ?? "—", "var(--chart-3)"]])}
    {legend("roc", "ROC · %", [["ROC9", active.roc?.toFixed(2) ?? "—", "var(--chart-1)"], ["MAROC9", active.maroc?.toFixed(2) ?? "—", "var(--chart-3)"]])}
    {legend("oi", "OPEN INTEREST · USD", [["OI", compact(active.oi), "var(--chart-2)"]])}
    {legend("taker", "TAKER BUY / SELL", [["Buy", compact(active.buy), "var(--positive)"], ["Sell", compact(active.sell), "var(--destructive)"]])}
    {panels.rsi[1] - panels.rsi[0] >= 35 && <>{axisLabel(columns.rsi[1], panels.rsi[0], "100")}{axisLabel(columns.rsi[1], panels.rsi[1], "0")}</>}
    {panels.roc[1] - panels.roc[0] >= 35 && <>{axisLabel(columns.roc[1], panels.roc[0], `+${rocExtent.toFixed(1)}`)}{axisLabel(columns.roc[1], panels.roc[1], `-${rocExtent.toFixed(1)}`)}</>}
    {oiValues.length > 0 && panels.oi[1] - panels.oi[0] >= 35 && <>{axisLabel(columns.oi[1], panels.oi[0], compact(oiMax))}{axisLabel(columns.oi[1], panels.oi[1], compact(oiMin))}</>}
  </>
}

export function MarketChart({ instId, onBack }: { instId: string; onBack: () => void }) {
  const [chart, setChart] = useState<ChartResponse | null>(null)
  const [hovered, setHovered] = useState<number | null>(null)
  const [error, setError] = useState("")
  const plotRef = useRef<HTMLDivElement>(null)
  const revision = useRef(-1)
  const [plotSize, setPlotSize] = useState({ width: 0, height: 0 })
  useEffect(() => {
    const element = plotRef.current
    if (!element) return
    const observer = new ResizeObserver(([entry]) => setPlotSize({ width: entry.contentRect.width, height: entry.contentRect.height }))
    observer.observe(element)
    return () => observer.disconnect()
  }, [])
  useEffect(() => {
    let stopped = false
    let timer: number
    let lastLoad = 0
    revision.current = -1
    const refresh = async () => {
      try {
        const loadChart = Date.now() - lastLoad >= 60_000
        const result = await window.webkit.messageHandlers.radar.postMessage({ chartInstId: instId, loadChart, sinceRevision: revision.current })
        if (stopped) return
        if (loadChart) lastLoad = Date.now()
        if (!("unchanged" in result)) {
          revision.current = result.error ? -1 : result.revision
          setChart(result)
        }
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
  return <main className="flex h-svh min-h-0 flex-col overflow-hidden overscroll-none">
    <header className="flex shrink-0 items-center gap-4 border-b px-5 py-3">
      <Button variant="ghost" size="sm" onClick={onBack}><ArrowLeft data-icon="inline-start" aria-hidden="true" />Markets</Button>
      <div className="min-w-0 flex-1">
        <h1 className="truncate text-lg font-semibold tracking-tight">{instId.replace(/-SWAP$/, "")}</h1>
        <p className="text-xs text-muted-foreground">OKX perpetual · 1h · Last 96 hours</p>
      </div>
      <Badge variant="secondary"><Radio aria-hidden="true" />{active && !active.confirmed ? "Live candle" : "Hourly chart"}</Badge>
    </header>
    {error && <p role="alert" className="shrink-0 border-b px-5 py-2 text-sm text-destructive">{error}</p>}
    <section aria-label={`${instId} chart`} className="flex min-h-0 flex-1 flex-col bg-card">
      {active && <div className="grid shrink-0 grid-cols-[minmax(9rem,1.2fr)_repeat(4,minmax(0,1fr))] items-center border-b px-5 py-2 tabular-nums" aria-live="off">
        <div className="min-w-0 border-r pr-3">
          <p className="text-xs text-muted-foreground">{hovered === null ? "Latest candle" : "Selected candle"}</p>
          <p className="truncate text-sm font-medium">{time(active.hour)}{active.confirmed ? "" : " · Live"}</p>
        </div>
        {([ ["Open", active.open], ["High", active.high], ["Low", active.low], ["Close", active.close] ] as const).map(([label, value]) => <div key={label} className="min-w-0 px-3">
          <p className="text-xs text-muted-foreground">{label}</p><p className="truncate text-sm font-semibold" title={price(value)}>{price(value)}</p>
        </div>)}
      </div>}
      <div ref={plotRef} className="min-h-0 flex-1">
        {bars.length && plotSize.width > 0 ? <svg viewBox={`0 0 ${plotSize.width} ${plotSize.height}`} className="h-full w-full focus-visible:outline-2 focus-visible:outline-ring" role="img" tabIndex={0} aria-label={`${instId} 96 hour candlestick chart with VWAP14, EMA200, shaded Bollinger bands, RSI with shaded 30 to 70 range, ROC, MAROC, open interest and taker buy and sell volume. Use left and right arrow keys to inspect candles.`} onPointerLeave={() => setHovered(null)} onKeyDown={event => {
          if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
            event.preventDefault()
            setHovered(current => Math.max(0, Math.min(bars.length - 1, (current ?? bars.length - 1) + (event.key === "ArrowLeft" ? -1 : 1))))
          } else if (event.key === "Home" || event.key === "End") {
            event.preventDefault()
            setHovered(event.key === "Home" ? 0 : bars.length - 1)
          }
        }} onPointerMove={event => {
          const rect = event.currentTarget.getBoundingClientRect()
          const svgX = event.clientX - rect.left, svgY = event.clientY - rect.top
          const { panels, columns } = chartLayout(plotSize.width, plotSize.height)
          const panel: Panel = svgY < panels.price[1] ? "price" : svgY < panels.oi[0]
            ? svgX < plotSize.width / 2 ? "rsi" : "roc"
            : svgX < plotSize.width / 2 ? "oi" : "taker"
          const [start, end] = columns[panel]
          setHovered(Math.max(0, Math.min(bars.length - 1, Math.floor((svgX - start) / (end - start) * bars.length))))
        }}>
          <Plot bars={bars} hovered={hovered} width={plotSize.width} height={plotSize.height} />
        </svg> : <p className="flex h-full items-center justify-center text-sm text-muted-foreground">{chart ? "No candle data available yet" : "Loading chart…"}</p>}
      </div>
    </section>
  </main>
}
