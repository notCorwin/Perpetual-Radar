import { Fragment, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import { ArrowDown, ArrowDownUp, ArrowUp, Radio, Search, Settings2 } from "lucide-react"
import katex from "katex"
import "katex/dist/katex.min.css"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyTitle } from "@/components/ui/empty"
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel, FieldSeparator, FieldTitle } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Popover, PopoverContent, PopoverDescription, PopoverHeader, PopoverTitle, PopoverTrigger } from "@/components/ui/popover"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Toggle } from "@/components/ui/toggle"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { cn } from "@/lib/utils"
import { compareMarketRows, compareMarketTurnover, defaultSortDescending, type SortKey } from "@/market-sort"
import { PERCENT_CHANGE_DESCRIPTION, formatPercent, percentageNumber, type PercentageValue } from "@/market-percent"
import { BREAK_DESCRIPTION, describeBreak, formatBreakPriorAge, formatBreakTime, type BreakDirection, type BreakResult } from "@/market-breaks"
import { BANDWIDTH_EXPANSION_DESCRIPTION, LOG_BB_DESCRIPTION, formatBandWidthExpansion, formatLiveBand } from "@/market-logbb"
import { MarketChart, type ChartPollResponse } from "@/MarketChart"
import { evaluateMarketOpportunity, OPPORTUNITY_DESCRIPTION } from "@/market-opportunity"
import { MarketOpportunity } from "@/MarketOpportunity"
import { MarketListViewport } from "@/MarketListViewport"
import { MarketFilters } from "@/MarketFilters"
import { emptyMarketFilters, matchesMarketFilters, parseMarketFilters, previewMarketFilters, type MarketFilterCombination, type MarketFilters as FilterConfig } from "@/market-filters"
import type { MarketRow } from "@/market-row"

type WindowAppearance = { frostedBackgroundEnabled: boolean; frostedBackgroundOpacity: number }
type Snapshot = WindowAppearance & { rows: MarketRow[]; updatedAt: number | null; error: string; revision: number; minimum24hTurnoverUSDT: number; spreadFilterEnabled: boolean; maximumSpreadPercent: number; contractAgeFilterEnabled: boolean; minimumContractAgeMonths: number; marketFiltersJSON: string; marketFilterCombinations: MarketFilterCombination[]; selectedMarketFilterCombinationID: string }
type UnchangedSnapshot = { unchanged: true; revision: number; error: string }
type SettingRequest = Partial<WindowAppearance> & { minimum24hTurnoverUSDT?: number; spreadFilterEnabled?: boolean; maximumSpreadPercent?: number; contractAgeFilterEnabled?: boolean; minimumContractAgeMonths?: number; marketFiltersJSON?: string; saveMarketFilterCombination?: { name: string; filtersJSON: string }; deleteMarketFilterCombination?: string; selectedMarketFilterCombinationID?: string }
type NativeBridge = {
  postMessage(request: { rocPeriod: number; marocPeriod: number; sinceRevision: number }): Promise<Snapshot | UnchangedSnapshot>
  postMessage(request: SettingRequest): Promise<Snapshot>
  postMessage(request: { captureChart: { x: number; y: number; width: number; height: number; backgroundRGB: number[] } }): Promise<{ ok: boolean }>
  postMessage(request: { chartInstId: string; loadChart?: boolean; sinceRevision?: number; chartEndHour?: number }): Promise<ChartPollResponse>
}
declare global {
  interface Window { radarAppearance?: WindowAppearance; webkit: { messageHandlers: { radar: NativeBridge } } }
}
const ROC_PERIOD = 9
const MAROC_PERIOD = 9
const formatIndicator = (value: number | null) => value === null ? "—" : value.toFixed(2)
const priceFormatter = new Intl.NumberFormat("en-US", { maximumSignificantDigits: 8 })
const turnoverFormatter = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 })
const formatPrice = (value: number | null) => value === null ? "—" : priceFormatter.format(value)
const directionClass = (value: PercentageValue) => {
  const number = percentageNumber(value)
  return number === null ? "text-muted-foreground" : number > 0 ? "text-positive" : number < 0 ? "text-destructive" : ""
}
const rsiClass = (value: number | null) => value === null ? "text-muted-foreground" : value > 70 ? "text-positive" : value < 30 ? "text-destructive" : ""
const RSI_PERIODS = [6, 12, 24] as const
const mathCache = new Map<string, string>()
const math = (formula: string) => {
  if (!mathCache.has(formula)) mathCache.set(formula, katex.renderToString(formula))
  return <span className="text-xs font-medium text-foreground" dangerouslySetInnerHTML={{ __html: mathCache.get(formula)! }} />
}

function BreakReadings({ result, direction }: { result: BreakResult; direction: BreakDirection }) {
  const description = describeBreak(result, direction)
  const hasEvent = result.status === "event"
  return <Fragment>
    <span className={cn("inline-flex items-baseline justify-end gap-1", hasEvent ? direction === "high" ? "text-positive" : "text-destructive" : "text-muted-foreground")} title={description}>
      <span className="sr-only">{direction === "high" ? "High breakout" : "Low breakdown"} </span>
      {hasEvent && <span aria-hidden="true">{direction === "high" ? "↑" : "↓"}</span>}
      {(hasEvent && result.live) || result.status === "loading" ? <Badge variant={result.status === "loading" ? "outline" : "secondary"}>{formatBreakTime(result)}</Badge> : formatBreakTime(result)}
    </span>
    <span className="text-xs text-muted-foreground" title={description}>
      <span className="sr-only">Previous {direction === "high" ? "high" : "low"} age at the break </span>{formatBreakPriorAge(result)}
    </span>
  </Fragment>
}

function App() {
  const revision = useRef(-1)
  const contractAgeDraftDirty = useRef(false)
  const backgroundOpacityDraftDirty = useRef(false)
  const filtersJSON = useRef<string | undefined>(undefined)
  const [listFilters, setListFilters] = useState<FilterConfig>(emptyMarketFilters)
  const [filterDraft, setFilterDraft] = useState<FilterConfig | null>(null)
  const [filterCombinations, setFilterCombinations] = useState<MarketFilterCombination[]>([])
  const [filterCombinationId, setFilterCombinationId] = useState("")
  const [rows, setRows] = useState<MarketRow[]>([])
  const [status, setStatus] = useState("Connecting")
  const [error, setError] = useState("")
  const [updatedAt, setUpdatedAt] = useState<number | null>(null)
  const [query, setQuery] = useState("")
  const [minimum24hTurnoverUSDT, setMinimum24hTurnoverUSDT] = useState(10_000_000)
  const [spreadFilterEnabled, setSpreadFilterEnabled] = useState(true)
  const [maximumSpreadPercent, setMaximumSpreadPercent] = useState(0.15)
  const [spreadDraft, setSpreadDraft] = useState("0.15")
  const [contractAgeFilterEnabled, setContractAgeFilterEnabled] = useState(true)
  const [minimumContractAgeMonths, setMinimumContractAgeMonths] = useState(6)
  const [contractAgeDraft, setContractAgeDraft] = useState("6")
  const [contractAgeError, setContractAgeError] = useState("")
  const [frostedBackgroundEnabled, setFrostedBackgroundEnabled] = useState(window.radarAppearance?.frostedBackgroundEnabled ?? true)
  const [frostedBackgroundOpacity, setFrostedBackgroundOpacity] = useState(window.radarAppearance?.frostedBackgroundOpacity ?? 0.3)
  const [backgroundOpacityDraft, setBackgroundOpacityDraft] = useState(String(window.radarAppearance?.frostedBackgroundOpacity ?? 0.3))
  const [backgroundOpacityError, setBackgroundOpacityError] = useState("")
  const [sort, setSort] = useState<SortKey>("opportunity")
  const [descending, setDescending] = useState(true)
  const [selected, setSelected] = useState<string | null>(null)
  useLayoutEffect(() => {
    document.documentElement.dataset.frostedBackground = String(frostedBackgroundEnabled)
    document.documentElement.style.setProperty("--window-background-opacity", String(frostedBackgroundEnabled ? frostedBackgroundOpacity : 1))
  }, [frostedBackgroundEnabled, frostedBackgroundOpacity])
  const acceptSnapshot = (snapshot: Snapshot) => {
    if (snapshot.revision < revision.current) return
    revision.current = snapshot.revision
    setRows(snapshot.rows)
    setMinimum24hTurnoverUSDT(snapshot.minimum24hTurnoverUSDT)
    setSpreadFilterEnabled(snapshot.spreadFilterEnabled)
    setMaximumSpreadPercent(snapshot.maximumSpreadPercent)
    if (document.activeElement?.id !== "maximum-spread") setSpreadDraft(String(snapshot.maximumSpreadPercent))
    setContractAgeFilterEnabled(snapshot.contractAgeFilterEnabled)
    setMinimumContractAgeMonths(snapshot.minimumContractAgeMonths)
    setFrostedBackgroundEnabled(snapshot.frostedBackgroundEnabled)
    setFrostedBackgroundOpacity(snapshot.frostedBackgroundOpacity)
    if (!backgroundOpacityDraftDirty.current && document.activeElement?.id !== "background-opacity") setBackgroundOpacityDraft(String(snapshot.frostedBackgroundOpacity))
    if (!contractAgeDraftDirty.current && document.activeElement?.id !== "minimum-contract-age") setContractAgeDraft(String(snapshot.minimumContractAgeMonths))
    if (filtersJSON.current !== snapshot.marketFiltersJSON) {
      filtersJSON.current = snapshot.marketFiltersJSON
      setListFilters(parseMarketFilters(snapshot.marketFiltersJSON))
    }
    setFilterCombinations(snapshot.marketFilterCombinations)
    setFilterCombinationId(snapshot.selectedMarketFilterCombinationID)
    setUpdatedAt(snapshot.updatedAt)
    setError(snapshot.error)
  }
  useEffect(() => {
    if (selected) return
    let stopped = false
    let timer: number
    const refresh = async () => {
      try {
        const snapshot = await window.webkit.messageHandlers.radar.postMessage({ rocPeriod: ROC_PERIOD, marocPeriod: MAROC_PERIOD, sinceRevision: revision.current })
        if (stopped) return
        if (!("unchanged" in snapshot)) acceptSnapshot(snapshot)
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
  }, [selected])

  const rankedRows = useMemo(() => rows.map(row => ({ ...row, opportunity: evaluateMarketOpportunity(row) })), [rows])
  const searchedRows = useMemo(() => rankedRows.filter(row => row.instId.toLowerCase().includes(query.trim().toLowerCase())), [rankedRows, query])
  const displayFilters = useMemo(() => filterDraft === null ? listFilters : previewMarketFilters(filterDraft), [listFilters, filterDraft])
  const visible = useMemo(() => {
    return searchedRows
      .filter(row => matchesMarketFilters(row, displayFilters))
      .sort((a, b) => compareMarketRows(a, b, sort, descending))
  }, [searchedRows, displayFilters, sort, descending])
  const listOrder = useMemo(() => visible.map(row => row.instId), [visible])
  const turnoverOrder = useMemo(() => rankedRows.filter(row => matchesMarketFilters(row, displayFilters)).sort(compareMarketTurnover).map(row => row.instId), [rankedRows, displayFilters])
  const saveFilters = async (filters: FilterConfig) => {
    acceptSnapshot(await window.webkit.messageHandlers.radar.postMessage({ marketFiltersJSON: JSON.stringify(filters) }))
    setFilterDraft(null)
  }
  const saveFilterCombination = async (name: string, filters: FilterConfig) => {
    const snapshot = await window.webkit.messageHandlers.radar.postMessage({ saveMarketFilterCombination: { name, filtersJSON: JSON.stringify(filters) } })
    acceptSnapshot(snapshot)
    const saved = snapshot.marketFilterCombinations.find(combination => combination.name === name.trim())
    if (!saved) throw new Error("Cannot find the saved combination. Try again.")
    return saved
  }
  const selectFilterCombination = async (id: string) => {
    acceptSnapshot(await window.webkit.messageHandlers.radar.postMessage({ selectedMarketFilterCombinationID: id }))
  }
  const deleteFilterCombination = async (id: string) => {
    acceptSnapshot(await window.webkit.messageHandlers.radar.postMessage({ deleteMarketFilterCombination: id }))
  }

  const changeSort = (key: SortKey) => {
    if (sort === key) setDescending(!descending)
    else { setSort(key); setDescending(defaultSortDescending(key)) }
  }

  const saveSetting = (request: SettingRequest) => {
    void window.webkit.messageHandlers.radar.postMessage(request)
      .then(acceptSnapshot)
      .catch(cause => setError(cause instanceof Error ? cause.message : "Cannot save setting"))
  }

  const changeTurnoverThreshold = (value: string) => {
    if (value) saveSetting({ minimum24hTurnoverUSDT: Number(value) })
  }

  const saveSpread = () => {
    const value = Number(spreadDraft)
    if (!spreadDraft.trim() || !Number.isFinite(value) || value < 0 || value > 100) {
      setSpreadDraft(String(maximumSpreadPercent))
      setError("Maximum spread must be between 0 and 100%")
      return
    }
    if (value !== maximumSpreadPercent) saveSetting({ maximumSpreadPercent: value })
    else setSpreadDraft(String(value))
  }

  const saveContractAge = () => {
    const value = Number(contractAgeDraft)
    if (!contractAgeDraft.trim() || !Number.isInteger(value) || value < 1 || value > 1200) {
      setContractAgeError("Enter a whole number from 1 to 1200 months.")
      return
    }
    contractAgeDraftDirty.current = false
    setContractAgeError("")
    setContractAgeDraft(String(value))
    if (value !== minimumContractAgeMonths) saveSetting({ minimumContractAgeMonths: value })
  }

  const saveBackgroundOpacity = () => {
    const value = Number(backgroundOpacityDraft)
    if (!backgroundOpacityDraft.trim() || !Number.isFinite(value) || value < 0 || value > 1) {
      setBackgroundOpacityError("Enter a number from 0 to 1.")
      return
    }
    backgroundOpacityDraftDirty.current = false
    setBackgroundOpacityError("")
    setBackgroundOpacityDraft(String(value))
    if (value !== frostedBackgroundOpacity) saveSetting({ frostedBackgroundOpacity: value })
  }

  const header = (label: string, key: SortKey, formula: string, description?: string) => {
    const SortIcon = sort !== key ? ArrowDownUp : descending ? ArrowDown : ArrowUp
    return <Button variant="ghost" size="sm" className={cn("h-auto min-h-6 gap-1", key === "turnover24hUSDT" && "border-l-0 pl-0")} onClick={() => changeSort(key)} aria-label={`Sort by ${label}`} aria-pressed={sort === key} title={description}>
      {math(formula)}<SortIcon data-icon="inline-end" aria-hidden="true" />
    </Button>
  }

  if (selected) return <MarketChart instId={selected} listOrder={listOrder} turnoverOrder={turnoverOrder} onSelect={setSelected} onBack={() => setSelected(null)} />

  return (
    <MarketListViewport>
    <main className="flex min-h-[inherit] flex-col">
      <header className="flex items-center gap-3 border-b px-4 py-3 whitespace-nowrap">
        <h1 className="text-base font-semibold tracking-tight">Perpetual Radar</h1>
        <span className="text-xs text-muted-foreground">OKX · USDT swaps · 1h · 24h turnover ≥ {minimum24hTurnoverUSDT / 1_000_000}M USDT{spreadFilterEnabled ? ` · spread ≤ ${maximumSpreadPercent}%` : ""}{contractAgeFilterEnabled ? ` · age ≥ ${minimumContractAgeMonths} ${minimumContractAgeMonths === 1 ? "month" : "months"}` : ""}</span>
        <span className="text-xs tabular-nums text-muted-foreground">{visible.length} / {rows.length} markets</span>
        <Popover onOpenChange={open => { if (!open) { if (contractAgeDraftDirty.current) saveContractAge(); if (backgroundOpacityDraftDirty.current) saveBackgroundOpacity() } }}>
          <PopoverTrigger asChild><Button variant="outline" size="sm"><Settings2 data-icon="inline-start" aria-hidden="true" />Settings</Button></PopoverTrigger>
          <PopoverContent align="end" className="max-h-(--radix-popover-content-available-height) overflow-y-auto">
            <PopoverHeader>
              <PopoverTitle>Settings</PopoverTitle>
              <PopoverDescription>Filter swaps and customize the window background.</PopoverDescription>
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
              <Field>
                <FieldTitle id="spread-limit-label">Maximum spread (%)</FieldTitle>
                <div className="flex items-center gap-2">
                  <Toggle variant="outline" size="sm" pressed={spreadFilterEnabled} onPressedChange={enabled => saveSetting({ spreadFilterEnabled: enabled })} aria-label="Enable maximum spread filter">{spreadFilterEnabled ? "On" : "Off"}</Toggle>
                  <Input id="maximum-spread" type="number" min="0" max="100" step="any" inputMode="decimal" aria-labelledby="spread-limit-label" value={spreadDraft} onChange={event => setSpreadDraft(event.target.value)} onBlur={saveSpread} onKeyDown={event => { if (event.key === "Enter") event.currentTarget.blur() }} />
                </div>
              </Field>
              <Field data-invalid={Boolean(contractAgeError)}>
                <FieldLabel htmlFor="minimum-contract-age">Minimum contract age (months)</FieldLabel>
                <div className="flex items-center gap-2">
                  <Toggle variant="outline" size="sm" pressed={contractAgeFilterEnabled} onPressedChange={enabled => saveSetting({ contractAgeFilterEnabled: enabled })} aria-label="Enable minimum contract age filter">{contractAgeFilterEnabled ? "On" : "Off"}</Toggle>
                  <Input id="minimum-contract-age" name="minimumContractAgeMonths" type="number" min="1" max="1200" step="1" inputMode="numeric" autoComplete="off" aria-describedby={contractAgeError ? "contract-age-description contract-age-error" : "contract-age-description"} aria-invalid={Boolean(contractAgeError)} value={contractAgeDraft} onChange={event => { contractAgeDraftDirty.current = true; setContractAgeDraft(event.target.value); setContractAgeError("") }} onBlur={saveContractAge} onKeyDown={event => { if (event.key === "Enter") event.currentTarget.blur() }} />
                </div>
                <FieldDescription id="contract-age-description">Calendar months since OKX listing. Unknown dates are hidden while enabled.</FieldDescription>
                {contractAgeError && <FieldError id="contract-age-error" role="alert">{contractAgeError}</FieldError>}
              </Field>
              <FieldSeparator />
              <Field orientation="horizontal">
                <FieldLabel htmlFor="frosted-background">Frosted background</FieldLabel>
                <Toggle id="frosted-background" variant="outline" size="sm" pressed={frostedBackgroundEnabled} onPressedChange={enabled => saveSetting({ frostedBackgroundEnabled: enabled })} aria-label="Enable frosted background">{frostedBackgroundEnabled ? "On" : "Off"}</Toggle>
              </Field>
              <Field data-invalid={Boolean(backgroundOpacityError)} data-disabled={!frostedBackgroundEnabled}>
                <FieldLabel htmlFor="background-opacity">Background opacity</FieldLabel>
                <Input id="background-opacity" name="frostedBackgroundOpacity" type="number" min="0" max="1" step="0.05" inputMode="decimal" autoComplete="off" disabled={!frostedBackgroundEnabled} aria-describedby={backgroundOpacityError ? "background-opacity-description background-opacity-error" : "background-opacity-description"} aria-invalid={Boolean(backgroundOpacityError)} value={backgroundOpacityDraft} onChange={event => { backgroundOpacityDraftDirty.current = true; setBackgroundOpacityDraft(event.target.value); setBackgroundOpacityError("") }} onBlur={saveBackgroundOpacity} onKeyDown={event => { if (event.key === "Enter") event.currentTarget.blur() }} />
                <FieldDescription id="background-opacity-description">0 reveals more of the blurred desktop; 1 is solid. Text and charts stay opaque.</FieldDescription>
                {backgroundOpacityError && <FieldError id="background-opacity-error" role="alert">{backgroundOpacityError}</FieldError>}
              </Field>
            </FieldGroup>
          </PopoverContent>
        </Popover>
        <div className="relative ml-auto w-64 shrink-0">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
          <Input aria-label="Search contracts" placeholder="Search contracts" value={query} onChange={event => setQuery(event.target.value)} className="pl-8" />
        </div>
        <Badge variant={status === "Live" ? "secondary" : "outline"} aria-live="polite">
          <Radio aria-hidden="true" />{status}
        </Badge>
        <span className="text-xs text-muted-foreground">{updatedAt ? `Updated ${new Date(updatedAt).toLocaleTimeString("en-US")}` : "Waiting for data"}</span>
      </header>
      <MarketFilters filters={listFilters} draft={filterDraft} onDraftChange={setFilterDraft} onApply={saveFilters} combinations={filterCombinations} combinationId={filterCombinationId} onSelectCombination={selectFilterCombination} onSaveCombination={saveFilterCombination} onDeleteCombination={deleteFilterCombination} matches={visible.length} total={searchedRows.length} />
      {error && <p role="alert" className="border-b px-4 py-2 text-sm text-destructive">{error}</p>}
      <section aria-label="Perpetual swap markets" className="flex-1">
        <Table className="table-auto">
          <TableHeader>
            <TableRow className="bg-muted/30">
              <TableHead className="py-1.5 pl-[var(--market-table-leading-inset)] text-left" aria-sort={sort === "turnover24hUSDT" ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-start">
                  {header("Turnover", "turnover24hUSDT", String.raw`\operatorname{Turnover}`)}
                </div>
              </TableHead>
              <TableHead className="text-center" aria-sort={sort === "opportunity" ? descending ? "descending" : "ascending" : "none"}>{header("Opportunity", "opportunity", String.raw`\operatorname{Opportunity}`, OPPORTUNITY_DESCRIPTION)}</TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={["highBreakout", "highBreakoutPriorAge", "lowBreakdown", "lowBreakdownPriorAge"].includes(sort) ? descending ? "descending" : "ascending" : "none"}>
                <div className="mx-auto grid w-max grid-cols-[max-content_max-content] items-center gap-x-3">
                  {header("High breakout · 48h", "highBreakout", String.raw`\text{High breakout}\cdot48\,\mathrm{h}`, BREAK_DESCRIPTION)}
                  {header("High age", "highBreakoutPriorAge", String.raw`\text{High age}`, "Sort by the previous high's age at the breakout, longest first. Tied highs use the most recent occurrence.")}
                  {header("Low breakdown · 48h", "lowBreakdown", String.raw`\text{Low breakdown}\cdot48\,\mathrm{h}`, BREAK_DESCRIPTION)}
                  {header("Low age", "lowBreakdownPriorAge", String.raw`\text{Low age}`, "Sort by the previous low's age at the breakdown, longest first. Tied lows use the most recent occurrence.")}
                </div>
              </TableHead>
              <TableHead className="text-center" aria-sort={sort === "takerRatio" ? descending ? "descending" : "ascending" : "none"}>{header("Taker buy-sell ratio", "takerRatio", String.raw`\frac{Buy_t-Sell_t}{Buy_t+Sell_t}\times100\%`)}</TableHead>
              <TableHead className="text-center" aria-sort={sort === "oiChange" ? descending ? "descending" : "ascending" : "none"}>{header("OI Relative Change", "oiChange", String.raw`\text{OI Relative Change}`, `Hourly OI relative change. ${PERCENT_CHANGE_DESCRIPTION}`)}</TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort === "roc" || sort === "maroc" ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {header(`ROC ${ROC_PERIOD}`, "roc", String.raw`\operatorname{ROC}_{${ROC_PERIOD}}\,(\%)`, `${ROC_PERIOD}-hour price change. ${PERCENT_CHANGE_DESCRIPTION}`)}
                  {header(`MAROC ${MAROC_PERIOD}`, "maroc", String.raw`\operatorname{MAROC}_{${MAROC_PERIOD}}\,(\%)`, `Mean of the latest ${MAROC_PERIOD} hourly ROC readings, as a percentage.`)}
                </div>
              </TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort.startsWith("rsi") ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {RSI_PERIODS.map(period => <Fragment key={period}>{header(`RSI ${period}`, `rsi${period}`, String.raw`\operatorname{RSI}_{${period}}`)}</Fragment>)}
                </div>
              </TableHead>
              <TableHead className="py-1.5 text-center" aria-sort={sort.startsWith("logBB") ? descending ? "descending" : "ascending" : "none"}>
                <div className="flex flex-col items-center">
                  {header("Log BB · Live", "logBBAboveBand", String.raw`\operatorname{LogBB}_{\mathrm{Live}}`, LOG_BB_DESCRIPTION)}
                  {header("Bandwidth expansion", "logBBExpansion", String.raw`\text{Bandwidth expansion}`, BANDWIDTH_EXPANSION_DESCRIPTION)}
                </div>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {visible.length ? visible.map(row => <TableRow key={row.instId} className="cursor-pointer hover:bg-accent/50 focus-visible:bg-accent/50 focus-visible:outline-2 focus-visible:outline-ring focus-visible:-outline-offset-2" tabIndex={0} aria-label={`View ${row.instId} chart`} onClick={() => setSelected(row.instId)} onKeyDown={event => {
              if (event.key === "Enter" || event.key === " ") { event.preventDefault(); setSelected(row.instId) }
            }}>
              <TableCell className="pl-[var(--market-table-leading-inset)] text-left" title={row.instId}>
                <span className="font-medium">{row.instId.replace(/-USDT-SWAP$/, "")}</span>
                <div className="flex justify-start gap-2 text-xs tabular-nums">
                  <span>{formatPrice(row.price)}</span>
                  <span className={directionClass(row.priceChange)} title={`Price change from the previous completed hour. ${PERCENT_CHANGE_DESCRIPTION}`}>{formatPercent(row.priceChange)}</span>
                </div>
                <div className="flex items-center justify-start gap-3 text-xs tabular-nums">
                  <span className="flex gap-1"><span className="text-muted-foreground">Low</span><span>{formatPrice(row.currentLow)}</span></span>
                  <span className="flex gap-1"><span className="text-muted-foreground">High</span><span>{formatPrice(row.currentHigh)}</span></span>
                </div>
                <div className="flex items-center justify-start gap-1 text-xs tabular-nums" title={`${row.turnover24hUSDT.toLocaleString("en-US", { maximumFractionDigits: 2 })} USDT`}>
                  <span className="text-muted-foreground">Turnover</span><span>{turnoverFormatter.format(row.turnover24hUSDT)} USDT</span>
                </div>
              </TableCell>
              <TableCell className="text-center tabular-nums"><MarketOpportunity instId={row.instId} opportunity={row.opportunity} /></TableCell>
              <TableCell className="text-center tabular-nums">
                <div className="mx-auto grid w-max grid-cols-[max-content_max-content] items-baseline gap-x-3 text-right">
                  <BreakReadings result={row.highBreakout} direction="high" />
                  <BreakReadings result={row.lowBreakdown} direction="low" />
                </div>
              </TableCell>
              <TableCell className={cn("text-center tabular-nums", directionClass(row.takerRatio))} title={row.buy !== null && row.sell !== null ? `Buy ${row.buy.toLocaleString("en-US")} / Sell ${row.sell.toLocaleString("en-US")} contracts` : "Loading current-hour taker volume"}>{formatPercent(row.takerRatio)}</TableCell>
              <TableCell className={cn("text-center tabular-nums", directionClass(row.oiChange))}>{formatPercent(row.oiChange)}</TableCell>
              <TableCell className="text-center tabular-nums">
                <div className="mx-auto grid w-max grid-cols-[max-content_max-content] gap-x-3 text-right">
                  <span className={directionClass(row.roc)}><span className="sr-only">ROC </span>{formatPercent(row.roc)}</span>
                  <span className={directionClass(row.rocChange)} title={`Hourly ROC change. ${PERCENT_CHANGE_DESCRIPTION}`}><span className="sr-only">ROC hourly change </span>{formatPercent(row.rocChange)}</span>
                  <span className={directionClass(row.maroc)}><span className="sr-only">MAROC </span>{formatPercent(row.maroc)}</span>
                  <span className={directionClass(row.marocChange)} title={`Hourly MAROC change. ${PERCENT_CHANGE_DESCRIPTION}`}><span className="sr-only">MAROC hourly change </span>{formatPercent(row.marocChange)}</span>
                </div>
              </TableCell>
              <TableCell className="text-center tabular-nums">
                <div className="flex flex-col items-center text-xs">
                  {RSI_PERIODS.map(period => <div key={period} className="flex gap-1"><span className="text-muted-foreground">{period}</span><span className={rsiClass(row[`rsi${period}`])}>{formatIndicator(row[`rsi${period}`])}</span></div>)}
                </div>
              </TableCell>
              <TableCell className="text-center tabular-nums">
                <div className="flex flex-col items-center text-xs">
                  <div className="flex gap-1" title={LOG_BB_DESCRIPTION}><span className="text-muted-foreground">Live</span><span className={cn(row.logBBAboveBand === null ? "text-muted-foreground" : row.logBBAboveBand === "below" ? "text-destructive" : "text-positive")}>{formatLiveBand(row.logBBAboveBand)}</span></div>
                  <div className="flex gap-1" title={BANDWIDTH_EXPANSION_DESCRIPTION}><span className="text-muted-foreground">Expansion</span><span className={cn(row.logBBExpansion && row.logBBExpansion.hours > 0 ? "text-positive" : "text-muted-foreground")}>{formatBandWidthExpansion(row.logBBExpansion)}</span></div>
                </div>
              </TableCell>
            </TableRow>) : <TableRow><TableCell colSpan={8} className="py-12">
              <Empty>
                <EmptyHeader><EmptyTitle>{rows.length ? "No matching contracts" : "Waiting for eligible contracts"}</EmptyTitle><EmptyDescription>{rows.length ? "Adjust the indicator conditions or search to show more markets." : "OKX data is loading. Settings control the turnover, spread, and listing age of eligible markets."}</EmptyDescription></EmptyHeader>
                <EmptyContent>
                  {filterDraft !== null && <Button variant="outline" size="sm" onClick={() => setFilterDraft(null)}>Discard preview</Button>}
                  {listFilters.rules.length > 0 && <Button variant="outline" size="sm" onClick={() => { void saveFilters(emptyMarketFilters()).catch(cause => setError(cause instanceof Error ? cause.message : "Cannot clear filters")) }}>Clear indicator filters</Button>}
                  {query && <Button variant="ghost" size="sm" onClick={() => setQuery("")}>Clear search</Button>}
                </EmptyContent>
              </Empty>
            </TableCell></TableRow>}
          </TableBody>
        </Table>
      </section>
    </main>
    </MarketListViewport>
  )
}

export default App
