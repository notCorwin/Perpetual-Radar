import { useEffect, useState } from 'react'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { TraceNode } from '@/FilterExplanation'
import { ResearchChart } from '@/ResearchChart'
import { longPrice } from '@/long-decisions'
import { parseFilterConfig, type FilterTrace } from '@/rule-engine'
import { requestResearch, researchPercent, researchTime, type DataManifest, type ResearchInputs, type ResearchLongTrade, type StudyReport } from '@/research-types'

export function LongTradeResults({ report, inputs, manifest }: { report: StudyReport; inputs: ResearchInputs; manifest: DataManifest | null }) {
  const [trades, setTrades] = useState<ResearchLongTrade[]>([]), [count, setCount] = useState(0), [offset, setOffset] = useState(0), [error, setError] = useState('')
  const [trade, setTrade] = useState<ResearchLongTrade | null>(null), [anchor, setAnchor] = useState('entry')
  const page = async (start: number) => {
    try {
      const result = await requestResearch({ action: 'trades', studyID: report.studyID, offset: start })
      setTrades(result.trades ?? []); setCount(result.count ?? 0); setOffset(start); setError('')
      return result.trades ?? []
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Cannot read frozen Long trades.'); return [] }
  }
  useEffect(() => {
    let stopped = false
    void requestResearch({ action: 'trades', studyID: report.studyID, offset: 0 }).then(result => { if (!stopped) { setTrades(result.trades ?? []); setCount(result.count ?? 0); setOffset(0) } }).catch(cause => { if (!stopped) setError(String(cause)) })
    return () => { stopped = true }
  }, [report.studyID])
  const navigate = async (step: number) => {
    if (!trade) return
    const index = trades.findIndex(t => t.id === trade.id)+step
    if (index >= 0 && index < trades.length) { setTrade(trades[index]); setAnchor('entry') }
    else {
      const next = offset + (step > 0 ? 50 : -50)
      if (next >= 0 && next < count) { const rows = await page(next); setTrade(step > 0 ? rows[0] : rows.at(-1) ?? null); setAnchor('entry') }
    }
  }
  const stats = report.long!, context = { metrics: inputs.metrics, expressions: {}, units: {}, templates: inputs.templates }
  const event = trade && (anchor === 'exit' && trade.exitEvent ? trade.exitEvent : trade.entryEvent)
  return <section className="flex flex-col gap-4" aria-label="Long strategy trades">
    <div className="flex items-center gap-3"><h3 className="font-semibold">Complete Long trades</h3><Badge variant="secondary">{stats.closed} closed</Badge><Badge variant="outline">{stats.open} open</Badge><Badge variant="outline">{stats.incomplete} incomplete</Badge><Badge variant="outline">{stats.uncertain} uncertain</Badge></div>
    <p className="text-xs text-muted-foreground">Exit filters determine the actual holding period. Gross profit {stats.grossProfit?.toLocaleString('en-US', { maximumFractionDigits: 4 }) ?? '—'} USDT across 1 USDT trades · Available modeled net profit {stats.netProfit?.toLocaleString('en-US', { maximumFractionDigits: 4 }) ?? '—'} USDT · Gross profit factor {stats.profitFactor?.toFixed(3) ?? '—'} · Mean hold {stats.averageHours?.toFixed(2) ?? '—'}h. Open trades are retained without a forced final sale.</p>
    {error && <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>}
    <Table aria-label="Long backtest trades"><TableHeader><TableRow>{['Contract', 'Entry open (UTC)', 'Entry price', 'Exit open (UTC)', 'Exit price', 'Hold', 'State', 'Gross', 'Net', 'MFE', 'MAE', 'Coverage / evidence'].map(label => <TableHead key={label}>{label}</TableHead>)}</TableRow></TableHeader>
      <TableBody>{trades.map(t => <TableRow key={t.id}><TableCell>{t.instrument}</TableCell><TableCell>{researchTime(t.entryTime)}</TableCell><TableCell>{longPrice(t.entryPrice)}</TableCell><TableCell>{t.exitTime == null ? 'Open' : researchTime(t.exitTime)}</TableCell><TableCell>{longPrice(t.exitPrice)}</TableCell><TableCell>{t.exitTime == null ? '—' : t.outcome.hours + 'h'}</TableCell><TableCell><Badge variant={t.status === 'Closed' ? 'secondary' : 'outline'}>{t.status}</Badge></TableCell><TableCell>{researchPercent(t.outcome.gross)}</TableCell><TableCell>{researchPercent(t.outcome.net)}</TableCell><TableCell>{researchPercent(t.outcome.mfe)}</TableCell><TableCell>{researchPercent(t.outcome.mae)}</TableCell><TableCell><Button variant="ghost" size="sm" aria-label={'Inspect Long trade ' + t.instrument} onClick={() => { setTrade(t); setAnchor('entry') }}>Inspect trade</Button><p className="text-xs text-muted-foreground">{t.entryEvent.split}{t.crossesSplit ? " · Crosses split" : ""}</p><p className="max-w-64 text-xs text-muted-foreground">{t.outcome.reason ?? t.outcome.netReason ?? (t.uncertain ? 'Exit evaluation crossed missing input hours.' : 'Complete')}</p></TableCell></TableRow>)}</TableBody></Table>
    <div className="flex items-center gap-3"><Button variant="outline" disabled={offset === 0} onClick={() => void page(Math.max(0,offset-50))}>Previous trades</Button><span className="text-xs text-muted-foreground">{count ? offset+1 : 0}–{Math.min(count,offset+trades.length)} / {count}</span><Button variant="outline" disabled={offset+50 >= count} onClick={() => void page(offset+50)}>Next trades</Button></div>
    <Dialog open={Boolean(trade)} onOpenChange={open => { if (!open) setTrade(null) }}><DialogContent className="flex h-[min(calc(var(--market-list-layout-height)*0.94),80rem)] w-[min(calc(var(--market-list-layout-width)*0.94),100rem)] max-w-none scale-(--market-list-scale) flex-col sm:max-w-none">
      <DialogHeader><DialogTitle>{trade?.instrument} · Long entry and exit evidence</DialogTitle><DialogDescription>{trade && researchTime(trade.entryTime)} → {trade?.exitTime == null ? 'Open at end of study' : researchTime(trade.exitTime)} · {trade?.status} · Frozen strategy and data</DialogDescription></DialogHeader>
      {trade && event && <div className="flex min-h-0 flex-col gap-4 overflow-y-auto">
        <div className="flex items-center gap-3"><ToggleGroup type="single" variant="outline" value={anchor} onValueChange={value => { if (value) setAnchor(value) }} aria-label="Trade chart anchor"><ToggleGroupItem value="entry">Entry chart</ToggleGroupItem><ToggleGroupItem value="exit" disabled={!trade.exitEvent}>Exit chart</ToggleGroupItem></ToggleGroup><span className="flex-1 text-xs text-muted-foreground">Gross {researchPercent(trade.outcome.gross)} · Net {researchPercent(trade.outcome.net)} · {trade.outcome.hours}h</span></div>
        <ResearchChart key={event.id} event={event} onNavigate={step => void navigate(step)} />
        <h3 className="font-semibold">Entry filter at the entry signal close</h3><TraceNode trace={JSON.parse(trade.entryEvent.traceJSON) as FilterTrace} config={parseFilterConfig(report.spec.rules[0].filtersJSON)} context={context} />
        <h3 className="font-semibold">Exit filter at the exit signal close</h3>{trade.exitEvent ? <TraceNode trace={JSON.parse(trade.exitEvent.traceJSON) as FilterTrace} config={parseFilterConfig(report.spec.rules[1].filtersJSON)} context={context} /> : <p className="text-sm text-muted-foreground">{trade.outcome.reason ?? 'No executable exit in the selected range.'}</p>}
        {(trade.entryEvent.split === 'Purged' || trade.crossesSplit) && <Alert variant="warning"><AlertDescription>{trade.entryEvent.split === 'Purged' ? 'This entry falls within the 48-hour split purge and is excluded from primary statistics.' : 'This trade crosses a time-split boundary. It is excluded from that split’s statistics.'}</AlertDescription></Alert>}
        {trade.unknownHours > 0 && <Alert variant="warning"><AlertDescription>{trade.unknownHours} exit-evaluation hours had missing inputs. This trade is excluded from the primary statistics.</AlertDescription></Alert>}
        <details><summary>Frozen source provenance</summary><p className="my-2 break-all text-xs text-muted-foreground">{manifest?.digest} · {manifest?.engine}</p><Table aria-label="Long trade provenance"><TableHeader><TableRow><TableHead>Source</TableHead><TableHead>Range (UTC)</TableHead><TableHead>SHA-256</TableHead></TableRow></TableHeader><TableBody>{manifest?.sources.filter(source => [...trade.entryEvent.sources,...(trade.exitEvent?.sources ?? [])].includes(source.id)).map(source => <TableRow key={source.id}><TableCell className="max-w-80 break-all text-xs">{source.kind} · {source.url}</TableCell><TableCell>{researchTime(source.from)} → {researchTime(source.through)}</TableCell><TableCell className="max-w-64 break-all text-xs">{source.rawHash ?? '—'}</TableCell></TableRow>)}</TableBody></Table></details>
      </div>}
    </DialogContent></Dialog>
  </section>
}
