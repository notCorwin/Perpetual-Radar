import { useEffect, useState } from 'react'
import { Check, ChevronsUpDown, CircleHelp, ScanSearch, X } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from '@/components/ui/command'
import { FieldDescription, FieldError, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Popover, PopoverContent, PopoverTrigger } from '@/components/ui/popover'
import { Spinner } from '@/components/ui/spinner'
import { cn } from '@/lib/utils'
import { FilterReadings, type ReadingContext } from '@/FilterReadings'
import { newRuleID, previewResponseIsCurrent, type EditorExpression, type FilterMetric, type FilterTrace, type FilterTruth, type NativeMarketRow } from '@/rule-engine'
import type { ExpressionTemplate } from '@/filter-expression'

export function FilterTruthBadge({ value }: { value: FilterTruth | undefined }) {
  const Icon = value === 'true' ? Check : value === 'false' ? X : CircleHelp
  return <Badge variant="outline" className={cn(value === 'true' ? 'text-positive' : value === 'false' ? 'text-destructive' : 'text-muted-foreground')}><Icon aria-hidden="true" />{value === 'true' ? 'Match' : value === 'false' ? 'No match' : 'Data missing'}</Badge>
}
function nodeTraces(trace: FilterTrace, id: string): FilterTrace[] { return [...(trace.id === id ? [trace] : []), ...trace.children.flatMap(child => nodeTraces(child, id))] }
const formatHour = (hour: number) => new Date(hour).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' })
type Props = { nodeId: string; rows: NativeMarketRow[]; results: Record<string, FilterTruth>; filtersJSON: string | null; revision: number; instId: string | null; onSelect: (id: string) => void; onExplain: (id: string) => void; metrics: FilterMetric[]; expressions: Record<string, EditorExpression>; templates: ExpressionTemplate[]; units: Record<string, string>; valid: boolean }
function readingTraces(trace: FilterTrace): FilterTrace[] { return [...(Object.keys(trace.readings).length ? [trace] : []), ...trace.children.flatMap(readingTraces)] }
function HourlyReading({ trace, context }: { trace: FilterTrace; context: ReadingContext }) {
  return <div data-surface="panel" className="flex flex-col gap-1 rounded-md border bg-card p-2"><div className="flex items-center justify-between gap-2"><time className="text-xs text-muted-foreground" dateTime={new Date(trace.hour).toISOString()}>{formatHour(trace.hour)}</time><FilterTruthBadge value={trace.result} /></div><FilterReadings readings={trace.readings} {...context} />{trace.reason && <FieldDescription>{trace.reason}</FieldDescription>}</div>
}
export function FilterRulePreview({ nodeId, rows, results, filtersJSON, revision, instId, onSelect, onExplain, metrics, expressions, templates, units, valid }: Props) {
  const [open, setOpen] = useState(false), [search, setSearch] = useState('')
  const id = instId ?? rows[0]?.instId
  const key = `${id ?? ''}|${filtersJSON ?? ''}`
  const [detail, setDetail] = useState<{ key: string; revision: number; trace: FilterTrace; error?: string } | null>(null)
  const [error, setError] = useState('')
  const [showChecks, setShowChecks] = useState(false), [checkLimit, setCheckLimit] = useState(50)
  const trace = detail?.key === key ? detail.trace : null
  const traces = trace ? nodeTraces(trace, nodeId) : []
  const loading = Boolean(id && filtersJSON) && (detail?.key !== key || detail.revision < revision)
  useEffect(() => {
    if (!id || !filtersJSON) return
    let stopped = false
    const token = newRuleID()
    void window.webkit.messageHandlers.radar.postMessage({ explainMarketFilters: { instId: id, filtersJSON, token } }).then(response => {
      if (!stopped && response.instId === id && previewResponseIsCurrent(response, token, revision)) { setDetail({ key, revision: response.revision, trace: response.trace }); setError('') }
    }).catch(cause => { if (!stopped) setError(cause instanceof Error ? cause.message : 'Cannot load the rule reading.') })
    return () => { stopped = true }
  }, [id, filtersJSON, revision, key])
  const filtered = rows.filter(row => row.instId.toLowerCase().includes(search.toLowerCase())).slice(0, 50)
  const selectedTrace = traces[0]
  const checks = traces.flatMap(readingTraces)
  const latestChecks = checks.filter(item => item.hour === checks[0]?.hour).slice(0, 3)
  const context = { metrics, expressions, templates, units }
  return <FieldGroup className="gap-2 border-t pt-3" data-rule-preview>
    <FieldLabel>Check a contract</FieldLabel>
    <div className="flex items-center gap-2"><Popover open={open} onOpenChange={setOpen}><PopoverTrigger asChild><Button type="button" variant="outline" className="min-w-0 flex-1 justify-between" role="combobox" aria-expanded={open} aria-label="Choose preview contract"><span className="truncate">{id?.replace(/-USDT-SWAP$/, '') ?? 'Waiting for markets'}</span><ChevronsUpDown data-icon="inline-end" aria-hidden="true" /></Button></PopoverTrigger><PopoverContent className="w-80 p-0" align="start"><Command shouldFilter={false}><CommandInput placeholder="Search all contracts…" value={search} onValueChange={setSearch} /><CommandList><CommandEmpty>No contracts found.</CommandEmpty><CommandGroup>{filtered.map(row => <CommandItem key={row.instId} value={row.instId} onSelect={() => { onSelect(row.instId); setOpen(false) }}><span className="min-w-0 flex-1">{row.instId.replace(/-USDT-SWAP$/, '')}</span><FilterTruthBadge value={results[row.instId]} /></CommandItem>)}</CommandGroup></CommandList></Command></PopoverContent></Popover>{id && <Button type="button" variant="ghost" size="icon" aria-label="Explain all rules for this contract" onClick={() => onExplain(id)}><ScanSearch aria-hidden="true" /></Button>}</div>
    {!valid && <FieldDescription>Showing the last valid preview. Finish this draft to update the readings.</FieldDescription>}
    {loading && <FieldDescription className="flex items-center gap-2"><Spinner aria-hidden="true" />Updating readings…</FieldDescription>}
    {error && <FieldError role="alert">{error}</FieldError>}
    {selectedTrace ? <div className="flex flex-col gap-2" aria-live="polite"><div className="flex items-center justify-between gap-2"><FilterTruthBadge value={selectedTrace.result} /><time className="text-xs text-muted-foreground" dateTime={new Date(selectedTrace.hour).toISOString()}>{formatHour(selectedTrace.hour)}</time></div>
      <FilterReadings readings={selectedTrace.readings} {...context} />
      {!Object.keys(selectedTrace.readings).length && latestChecks.length > 0 && <><FieldDescription>Latest checked hour</FieldDescription>{latestChecks.map((item, index) => <HourlyReading key={`${item.id}:${item.hour}:${index}`} trace={item} context={context} />)}</>}
      {selectedTrace.reason && <FieldDescription>{selectedTrace.reason}</FieldDescription>}
      {selectedTrace.eventHours.length > 0 && <FieldDescription>Event path: {selectedTrace.eventHours.map(formatHour).join(' → ')}</FieldDescription>}
      {checks.length > 1 && <><Button type="button" variant="ghost" size="sm" className="justify-start" aria-expanded={showChecks} onClick={() => setShowChecks(!showChecks)}>{showChecks ? 'Hide' : 'Inspect'} {checks.length} hourly checks</Button>{showChecks && <div className="flex flex-col gap-2">{checks.slice(0, checkLimit).map((item, index) => <HourlyReading key={`${item.id}:${item.hour}:${index}`} trace={item} context={context} />)}{checks.length > checkLimit && <Button type="button" variant="outline" size="sm" onClick={() => setCheckLimit(checkLimit + 50)}>Show more hourly checks</Button>}</div>}</>}
    </div> : !loading && <FieldDescription>{rows.length ? 'This rule is not part of the last valid preview yet.' : 'Readings appear when market data arrives.'}</FieldDescription>}
  </FieldGroup>
}
