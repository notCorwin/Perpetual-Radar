import { useState } from 'react'
import { ArrowDownRight, ArrowUpRight, FlaskConical, ScanSearch } from 'lucide-react'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '@/components/ui/empty'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { cn } from '@/lib/utils'
import { researchTime } from '@/research-types'
import { phaseMatches, signalHasConflict, signalIsUnknown, signalMatches, type EntryPhase, type RadarSignal } from '@/radar-signals'
import type { NativeMarketRow } from '@/rule-engine'
import type { StrategyProfile, SuitePosition, SuiteReading } from '@/suite-types'

const price = new Intl.NumberFormat('en-US', { maximumSignificantDigits: 8 })
const turnover = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 2 })

type SignalChartAction = (instrument: string, order: string[]) => void

function SignalLane({ phase, signals, markets, onChart, onExplain }: { phase: EntryPhase; signals: RadarSignal[]; markets: Map<string, NativeMarketRow>; onChart: SignalChartAction; onExplain: (instrument: string) => void }) {
  const [page, setPage] = useState(0)
  const bullish = phase === 'bullishSetup', label = bullish ? 'Bullish Setup' : 'Bearish Reversal'
  const matching = signals.filter(signal => signalMatches(signal, phase)).sort((a, b) => Number(phaseMatches(b.confirmed, phase)) - Number(phaseMatches(a.confirmed, phase)) || (markets.get(b.instrument)?.turnover24hUSDT ?? 0) - (markets.get(a.instrument)?.turnover24hUSDT ?? 0) || a.instrument.localeCompare(b.instrument))
  const currentPage = Math.min(page, Math.max(0, Math.ceil(matching.length / 25) - 1))
  const confirmed = matching.filter(signal => phaseMatches(signal.confirmed, phase)).length
  const forming = matching.filter(signal => phaseMatches(signal.provisional, phase)).length
  return <section aria-label={label + ' signals'} className="flex min-w-0 flex-col rounded-lg border" data-signal-lane={phase}>
    <header className="flex items-start gap-3 border-b p-4">
      <div className={cn('mt-0.5', bullish ? 'text-positive' : 'text-destructive')}>{bullish ? <ArrowUpRight aria-hidden="true" /> : <ArrowDownRight aria-hidden="true" />}</div>
      <div className="flex min-w-0 flex-1 flex-col gap-1"><h2 className="font-semibold">{label}</h2><p className="text-xs text-muted-foreground">{bullish ? 'Long setups · also inspect Short exits' : 'Short setups · also inspect Long exits'}</p><p className="text-xs text-muted-foreground">{confirmed} confirmed · {forming} provisional</p></div>
      <Badge variant={bullish ? 'positive' : 'destructive'} aria-label={matching.length + ' ' + label + ' contracts'}>{matching.length}</Badge>
    </header>
    {matching.length ? <>
      <Table aria-label={label + ' contracts'}><TableHeader><TableRow><TableHead>Contract / market</TableHead><TableHead>Signal / decision</TableHead><TableHead className="text-right">Evidence</TableHead></TableRow></TableHeader><TableBody>{matching.slice(currentPage * 25, currentPage * 25 + 25).map(signal => {
        const market = markets.get(signal.instrument)
        return <TableRow key={signal.instrument} data-signal-instrument={signal.instrument}>
          <TableCell><Button variant="link" onClick={() => onChart(signal.instrument, matching.map(match => match.instrument))} aria-label={'View ' + signal.instrument + ' chart'}>{signal.instrument.replace(/-USDT-SWAP$/, '')}</Button><p className="text-xs">{market?.price == null ? '—' : price.format(market.price)} USDT</p><p className="text-xs text-muted-foreground">{market?.turnover24hUSDT == null ? 'Turnover —' : turnover.format(market.turnover24hUSDT) + ' USDT / 24h'}</p></TableCell>
          <TableCell><div className="flex flex-col items-start gap-1">{signalHasConflict(signal) && <Badge variant="warning">Both directions match</Badge>}{(['confirmed', 'provisional'] as const).map(source => {
            const reading = signal[source]
            return phaseMatches(reading, phase) && reading && <div key={source} className="flex flex-col items-start gap-1"><Badge variant={source === 'confirmed' ? 'secondary' : 'outline'} title={researchTime(reading.hour + (source === 'confirmed' ? 3_600_000 : 0))}>{source === 'confirmed' ? 'Confirmed' : 'Provisional'} · {source === 'confirmed' ? 'Closed hour' : 'Forming hour'}</Badge><span className="text-xs" title={reading.reason}>{reading.action}</span></div>
          })}</div></TableCell>
          <TableCell className="text-right"><Button variant="ghost" size="sm" onClick={() => onExplain(signal.instrument)} aria-label={'Explain ' + signal.instrument + ' phases'}><ScanSearch data-icon="inline-start" aria-hidden="true" />Explain</Button></TableCell>
        </TableRow>
      })}</TableBody></Table>
      {matching.length > 25 && <div className="flex items-center justify-between gap-2 border-t p-3"><Button variant="ghost" size="sm" disabled={currentPage === 0} onClick={() => setPage(currentPage - 1)} aria-label={'Previous ' + label + ' contracts'}>Previous</Button><span className="text-xs text-muted-foreground">{currentPage * 25 + 1}–{Math.min(matching.length, (currentPage + 1) * 25)} / {matching.length}</span><Button variant="ghost" size="sm" disabled={(currentPage + 1) * 25 >= matching.length} onClick={() => setPage(currentPage + 1)} aria-label={'Next ' + label + ' contracts'}>Next</Button></div>}
    </> : <Empty><EmptyHeader><EmptyTitle>No {label} matches</EmptyTitle><EmptyDescription>Watching every contract against this phase and its Universe. New matches appear here automatically.</EmptyDescription></EmptyHeader></Empty>}
  </section>
}

export function RadarSignalBoard({ profile, signals, positionReadings, rows, positions, paused, onChart, onExplain, onPositions, onResearch }: { profile: StrategyProfile; signals: RadarSignal[]; positionReadings: SuiteReading[]; rows: NativeMarketRow[]; positions: SuitePosition[]; paused?: boolean; onChart: SignalChartAction; onExplain: (instrument: string) => void; onPositions: () => void; onResearch: () => void }) {
  const markets = new Map(rows.map(row => [row.instId, row]))
  const unknown = signals.filter(signalIsUnknown).length, conflicts = signals.filter(signalHasConflict).length
  const held = positions.filter(position => position.exitedAt == null)
  const exits = positionReadings.filter(reading => reading.strategyID === profile.id && reading.revision === profile.revision && reading.position && reading.action.startsWith('Exit'))
  return <section aria-label="Strategy signal radar" className="flex flex-col gap-4 p-4" data-signal-board>
    <div className="flex items-center gap-3"><div className="flex min-w-0 flex-1 flex-col gap-1"><h2 className="font-semibold">Watch both directions</h2><p className="text-xs text-muted-foreground">{profile.name} · r{profile.revision} · Universe and phase evaluated together · Conflicting phases stay visible</p></div><Button variant="outline" onClick={onPositions}>Positions · {held.length}{exits.length > 0 ? ' · ' + exits.length + ' confirmed exits' : ''}</Button><Button variant="outline" onClick={onResearch}><FlaskConical data-icon="inline-start" aria-hidden="true" />Test strategy</Button></div>
    {paused && <Alert variant="warning"><AlertDescription>Monitoring is paused. Resume in Settings to collect new signals.</AlertDescription></Alert>}
    {(unknown > 0 || conflicts > 0 || !signals.length) && <p role="status" className="text-xs text-muted-foreground">{!signals.length ? 'Waiting for strategy inputs. ' : ''}{unknown > 0 ? unknown + ' contracts have Unknown entry inputs. Inspect All markets for missing data. ' : ''}{conflicts > 0 ? conflicts + ' contracts match both entry phases; inspect the evidence before choosing a direction.' : ''}</p>}
    <div className="grid grid-cols-2 items-start gap-4">{(['bullishSetup', 'bearishReversal'] as const).map(phase => <SignalLane key={profile.id + ':' + phase} phase={phase} signals={signals} markets={markets} onChart={onChart} onExplain={onExplain} />)}</div>
    {held.length > 0 && <p className="text-xs text-muted-foreground">Actual holdings are tracked separately. Exit rules continue outside Universe; open Positions to inspect holds, exits and inactive strategies.</p>}
  </section>
}
