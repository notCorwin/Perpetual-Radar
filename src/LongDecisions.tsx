import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { ArrowLeft, ChartNoAxesCombined, Check, Copy, Filter, FlaskConical, Plus, Save, Trash2 } from 'lucide-react'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from '@/components/ui/empty'
import { Field, FieldDescription, FieldGroup, FieldLabel } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Spinner } from '@/components/ui/spinner'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { TraceNode } from '@/FilterExplanation'
import { FilterTruthBadge } from '@/FilterRulePreview'
import { LongStrategyEditor } from '@/LongStrategyEditor'
import { useStrategyFilter } from '@/use-strategy-filter'
import { MarketChart } from '@/MarketChart'
import { MarketListViewport } from '@/MarketListViewport'
import { emptyFilterConfig, initialLibraryPreferences, parseFilterConfig, type FilterLibraryPreferences, type FilterTrace } from '@/rule-engine'
import { keepSnapshotValue } from '@/market-snapshot'
import { researchPercent, researchTime, RESEARCH_HOUR, type ResearchInputs, type StudySpec } from '@/research-types'
import { longPrice, longReturn, longStudyRules, requestLong, type LongDecisionRow, type LongPosition, type LongResponse, type LongStrategy } from '@/long-decisions'

const decisionRank = { 'Exit Long': 0, 'Enter Long': 1, Unknown: 2, 'Hold Long': 3, Wait: 4 }

export function LongDecisions({ active, inputs, onBack, onResearch }: { active: boolean; inputs: ResearchInputs; onBack: () => void; onResearch: (spec: StudySpec) => void }) {
  const [strategies, setStrategies] = useState<LongStrategy[]>([]), [positions, setPositions] = useState<LongPosition[]>([])
  const [selectedID, setSelectedID] = useState(''), [loaded, setLoaded] = useState<LongStrategy | null>(null), [name, setName] = useState('My Long strategy')
  const entry = useStrategyFilter(JSON.stringify(inputs.filters)), exit = useStrategyFilter(JSON.stringify(emptyFilterConfig()))
  const [preferences, setPreferences] = useState<FilterLibraryPreferences>(initialLibraryPreferences)
  const [tab, setTab] = useState('configure'), [filterTab, setFilterTab] = useState('entry'), [forming, setForming] = useState(false)
  const [decisions, setDecisions] = useState<LongDecisionRow[]>([]), [paused, setPaused] = useState(false)
  const [search, setSearch] = useState(''), [view, setView] = useState('all'), [page, setPage] = useState(0)
  const [openPage, setOpenPage] = useState(0), [exitPage, setExitPage] = useState(0)
  const [error, setError] = useState(''), [notice, setNotice] = useState(''), [pending, setPending] = useState(false)
  const [pollError, setPollError] = useState('')
  const [detail, setDetail] = useState<LongDecisionRow | null>(null), [chart, setChart] = useState<string | null>(null)
  const [record, setRecord] = useState<{ kind: 'open' | 'close'; instrument: string; price: string; time: string } | null>(null)
  const [confirm, setConfirm] = useState<{ kind: 'load' | 'delete' | 'remove'; strategy?: LongStrategy; position?: LongPosition } | null>(null)
  const initialized = useRef(false), mutation = useRef(false), requestEpoch = useRef(0)
  const selected = strategies.find(s => s.id === selectedID)
  const dirty = name !== (loaded?.name ?? 'My Long strategy') || entry.dirty || exit.dirty || Boolean(loaded && (
    entry.canonical && entry.canonical !== loaded.entryJSON || exit.canonical && exit.canonical !== loaded.exitJSON))
  const resetEntry = entry.reset, resetExit = exit.reset
  const load = useCallback((strategy: LongStrategy | null) => {
    setLoaded(strategy); setName(strategy?.name ?? 'My Long strategy')
    resetEntry(strategy?.entryJSON ?? JSON.stringify(inputs.filters)); resetExit(strategy?.exitJSON ?? JSON.stringify(emptyFilterConfig()))
    setNotice(''); setError('')
    setOpenPage(0)
  }, [inputs.filters, resetEntry, resetExit])
  const accept = useCallback((response: LongResponse) => {
    setPollError('')
    setStrategies(current => keepSnapshotValue(current, response.strategies)); setPositions(current => keepSnapshotValue(current, response.positions)); setPaused(response.paused)
    if (response.preferences) setPreferences(current => keepSnapshotValue(current, response.preferences!))
    if (response.decisions) setDecisions(current => keepSnapshotValue(current, response.decisions!))
  }, [])
  useEffect(() => {
    if (!active) return
    let stopped = false, timer: number
    const refresh = async () => {
      try {
        if (!mutation.current) {
          const epoch = requestEpoch.current
          const response = await requestLong(selectedID ? { action: 'evaluate', strategyID: selectedID, forming } : { action: 'inventory' })
          if (stopped || epoch !== requestEpoch.current) return
          accept(response)
          if (!initialized.current) {
            initialized.current = true
            const strategy = response.strategies.find(s => s.id === response.selectedID) ?? response.strategies[0]
            if (strategy) { setSelectedID(strategy.id); load(strategy); setTab('live') }
          }
        }
      } catch (cause) { if (!stopped) setPollError(cause instanceof Error ? cause.message : 'Cannot read Long decisions.') }
      finally {
        // A stale reply can be ignored while the live polling loop continues.
        if (!stopped) timer = window.setTimeout(refresh, 2000)
      }
    }
    void refresh(); return () => { stopped = true; window.clearTimeout(timer) }
    // A saved selection drives polling; editing the draft never changes its decisions.
  }, [active, selectedID, forming, accept, load])
  useEffect(() => {
    const openNotification = async () => {
      const id = window.radarNotificationStrategy
      if (!active || !id) return
      try {
        const response = await requestLong({ action: 'inventory' })
        const strategy = response.strategies.find(item => item.id === id)
        if (window.radarNotificationStrategy !== id) return
        if (!strategy) { delete window.radarNotificationStrategy; setError('The notified strategy is no longer saved.'); return }
        requestEpoch.current++; initialized.current = true
        accept(response); setSelectedID(id); load(strategy); setTab('live'); setView('holding'); setForming(false); setPage(0); setSearch(''); setChart(null); setDetail(null)
        delete window.radarNotificationStrategy
      } catch (cause) { setError(cause instanceof Error ? cause.message : 'Cannot open the notified strategy.') }
    }
    const handler = () => { void openNotification() }
    window.addEventListener('radar-open-long', handler); handler()
    return () => window.removeEventListener('radar-open-long', handler)
  }, [active, accept, load])
  const perform = async (action: () => Promise<void>) => {
    requestEpoch.current += 1; mutation.current = true; setPending(true); setError(''); setNotice('')
    try { await action() } catch (cause) { setError(cause instanceof Error ? cause.message : 'Cannot save this change.') }
    finally { mutation.current = false; setPending(false) }
  }
  const choose = async (strategy: LongStrategy | null) => {
    initialized.current = true; load(strategy); setSelectedID(strategy?.id ?? ''); setDecisions([])
    if (strategy) accept(await requestLong({ action: 'select', strategyID: strategy.id }))
    setTab('configure')
  }
  const chooseWithDraft = (strategy: LongStrategy | null) => { if (dirty) setConfirm({ kind: 'load', strategy: strategy ?? undefined }); else void perform(() => choose(strategy)) }
  const save = () => perform(async () => {
    if (!entry.valid || !exit.valid || !entry.canonical || !exit.canonical) throw new Error('Finish both valid filters before saving.')
    if (!name.trim()) { document.getElementById('long-strategy-name')?.focus(); throw new Error('Give the strategy a name.') }
    const response = await requestLong({ action: 'save', strategy: { id: loaded?.id ?? '', name: name.trim(), entryJSON: entry.canonical, exitJSON: exit.canonical, revision: loaded?.revision ?? 0, updatedAt: Date.now() } })
    accept(response)
    if (response.saved) { load(response.saved); setSelectedID(response.saved.id); accept(await requestLong({ action: 'evaluate', strategyID: response.saved.id, forming })); setTab('live'); setNotice('Both filters saved. Live decisions and new backtests use this strategy revision.') }
  })
  const savePreferences = async (value: FilterLibraryPreferences) => {
    await window.webkit.messageHandlers.radar.postMessage({ filterLibraryPreferencesJSON: JSON.stringify(value) }); setPreferences(value)
  }
  const backtest = () => {
    if (!selected) return
    onResearch({ name: selected.name + ' backtest', kind: 'long', rules: longStudyRules(selected), instruments: [], from: null, through: Math.floor(Date.now()/RESEARCH_HOUR)*RESEARCH_HOUR, direction: 'Long', sampling: 'entries', costs: null })
  }
  const beginRecord = (kind: 'open' | 'close', instrument: string, price?: number) => setRecord({ kind, instrument, price: price == null ? '' : String(price), time: new Date().toISOString().slice(0, 16) })
  const visible = useMemo(() => decisions.filter(row => row.instrument.toLowerCase().includes(search.trim().toLowerCase()) && (view === 'all' || view === 'signals' && ['Enter Long', 'Exit Long'].includes(row.action) || view === 'holding' && row.position || view === 'unknown' && row.action === 'Unknown')).sort((a, b) => decisionRank[a.action]-decisionRank[b.action] || a.instrument.localeCompare(b.instrument)), [decisions, search, view])
  const open = positions.filter(p => p.strategyID === selectedID && p.exitedAt == null)
  const tracked = positions.filter(p => p.exitedAt != null).slice().reverse()
  const contractPage = Math.min(page, Math.max(0, Math.ceil(visible.length / 50) - 1))
  const openIndex = Math.min(openPage, Math.max(0, Math.ceil(open.length / 50) - 1))
  const exitIndex = Math.min(exitPage, Math.max(0, Math.ceil(tracked.length / 50) - 1))
  const context = { metrics: inputs.metrics, expressions: {}, units: {}, templates: inputs.templates }
  const inspect = (row: LongDecisionRow) => perform(async () => {
    const response = await requestLong({ action: 'evaluate', strategyID: selectedID, forming, instrument: row.instrument })
    setDetail(response.decisions?.find(d => d.instrument === row.instrument) ?? row)
  })
  if (active && chart) return <MarketChart instId={chart} listOrder={visible.map(d => d.instrument)} turnoverOrder={visible.map(d => d.instrument)} onSelect={setChart} onBack={() => setChart(null)} />
  return <MarketListViewport><main className="flex min-h-[inherit] flex-col gap-4 p-4 tabular-nums" data-long-decisions>
    <header className="flex items-center gap-3 border-b pb-3">
      <Button variant="ghost" onClick={onBack}><ArrowLeft data-icon="inline-start" aria-hidden="true" />Radar</Button><Filter className="size-5" aria-hidden="true" /><h1 className="text-base font-semibold">Long Decisions</h1>
      <span className="flex-1 text-xs text-muted-foreground">Entry while flat · Exit while holding · Manual execution</span><Badge variant="outline">Long only</Badge>
      <Button variant="outline" disabled={!selected || pending} onClick={backtest}><FlaskConical data-icon="inline-start" aria-hidden="true" />Backtest saved strategy</Button>
    </header>
    {(error || pollError) && <Alert variant="destructive" role="alert"><AlertTitle>Long decisions need attention</AlertTitle><AlertDescription>{error || pollError}</AlertDescription></Alert>}
    {notice && <p role="status" className="text-sm text-muted-foreground">{notice}</p>}
    <FieldGroup className="grid grid-cols-[minmax(20rem,1fr)_auto_auto_auto] items-end gap-3">
      <Field><FieldLabel>Saved Long strategy</FieldLabel><Select value={selectedID} disabled={pending} onValueChange={id => { const next = strategies.find(s => s.id === id); if (next) chooseWithDraft(next) }}><SelectTrigger aria-label="Saved Long strategy"><SelectValue placeholder="Create your first Long strategy…" /></SelectTrigger><SelectContent><SelectGroup>{strategies.map(s => <SelectItem key={s.id} value={s.id}>{s.name} · v{s.revision}</SelectItem>)}</SelectGroup></SelectContent></Select></Field>
      <Button variant="outline" disabled={pending} onClick={() => chooseWithDraft(null)}><Plus data-icon="inline-start" aria-hidden="true" />New strategy</Button>
      <Button variant="outline" disabled={!selected || pending} onClick={() => { if (selected) { setLoaded(null); setName(name + ' copy'); setTab('configure') } }}><Copy data-icon="inline-start" aria-hidden="true" />Duplicate</Button>
      <Button variant="ghost" disabled={!selected || pending} aria-label="Delete Long strategy" onClick={() => setConfirm({ kind: 'delete', strategy: selected })}><Trash2 aria-hidden="true" /></Button>
    </FieldGroup>
    <Tabs value={tab} onValueChange={setTab}>
      <TabsList variant="line"><TabsTrigger value="live">Live decisions</TabsTrigger><TabsTrigger value="configure">Entry & exit filters</TabsTrigger><TabsTrigger value="positions">Tracked positions</TabsTrigger></TabsList>
      <TabsContent value="configure" className="flex flex-col gap-4">
        <FieldGroup className="grid grid-cols-[minmax(20rem,1fr)_auto] items-end gap-3"><Field><FieldLabel htmlFor="long-strategy-name">Strategy name</FieldLabel><Input id="long-strategy-name" name="longStrategyName" value={name} maxLength={80} autoComplete="off" onChange={e => setName(e.target.value)} /></Field>
          <Button disabled={pending || !entry.valid || !exit.valid || !name.trim()} onClick={() => void save()}>{pending ? <Spinner data-icon="inline-start" aria-hidden="true" /> : <Save data-icon="inline-start" aria-hidden="true" />}Save strategy</Button></FieldGroup>
        {(dirty || !loaded) && <Alert variant="warning"><AlertTitle>Strategy draft</AlertTitle><AlertDescription>Save both filters together to apply them. Live decisions and Backtest saved strategy use the saved revision. Drafts remain available when you return from Radar or Research.</AlertDescription></Alert>}
        <Tabs value={filterTab} onValueChange={setFilterTab}><TabsList><TabsTrigger value="entry">Entry filter</TabsTrigger><TabsTrigger value="exit">Exit filter</TabsTrigger></TabsList>
          <TabsContent forceMount value="entry" hidden={filterTab !== 'entry'}><LongStrategyEditor label="Entry filter" model={entry} inputs={inputs} preferences={preferences} onPreferences={savePreferences} active={active && tab === 'configure' && filterTab === 'entry'} strategyID={loaded?.id ?? ''} /></TabsContent>
          <TabsContent forceMount value="exit" hidden={filterTab !== 'exit'}><LongStrategyEditor label="Exit filter" model={exit} inputs={inputs} preferences={preferences} onPreferences={savePreferences} active={active && tab === 'configure' && filterTab === 'exit'} strategyID={loaded?.id ?? ''} /></TabsContent>
        </Tabs>
      </TabsContent>
      <TabsContent value="live" className="flex flex-col gap-4">
        {!selected ? <Empty><EmptyHeader><EmptyTitle>Build your Long decision filters</EmptyTitle><EmptyDescription>Configure an entry filter and an exit filter, then save the strategy.</EmptyDescription></EmptyHeader><Button onClick={() => setTab('configure')}>Configure filters</Button></Empty> : <>
          <FieldGroup className="grid grid-cols-[minmax(20rem,1fr)_auto_auto] items-end gap-4">
            <Field><FieldLabel htmlFor="long-search">Search contracts</FieldLabel><Input id="long-search" value={search} placeholder="Search a USDT perpetual…" onChange={e => { setSearch(e.target.value); setPage(0) }} /></Field>
            <Field><FieldLabel>Decision clock</FieldLabel><ToggleGroup type="single" variant="outline" value={forming ? 'forming' : 'close'} onValueChange={value => { if (value) { setForming(value === 'forming'); setDetail(null) } }} aria-label="Decision clock"><ToggleGroupItem value="close">Hourly close</ToggleGroupItem><ToggleGroupItem value="forming">Forming-hour preview</ToggleGroupItem></ToggleGroup></Field>
            <Field><FieldLabel>Show</FieldLabel><ToggleGroup type="single" variant="outline" value={view} onValueChange={value => { if (value) { setView(value); setPage(0) } }} aria-label="Decision view"><ToggleGroupItem value="all">All</ToggleGroupItem><ToggleGroupItem value="signals">Entry / Exit</ToggleGroupItem><ToggleGroupItem value="holding">Holding</ToggleGroupItem><ToggleGroupItem value="unknown">Unknown</ToggleGroupItem></ToggleGroup></Field>
          </FieldGroup>
          <p className="text-xs text-muted-foreground">{forming ? 'Preview uses the unfinished contract hour and can change. BTC risk exits remain confirmed signals on their own clock. Backtests use completed hourly closes.' : 'Contract readings use the just-completed hour; Closed rules keep their previous-hour offset. Explicit BTC clocks apply independently and can trigger immediate risk exits. Backtests check hourly closes.'} Position changes are recorded manually after you trade.</p>
          {paused && <Alert variant="warning"><AlertTitle>Monitoring paused</AlertTitle><AlertDescription>Cached readings remain visible; current decisions are Unknown. Resume monitoring in Radar settings.</AlertDescription></Alert>}
          <Table aria-label="Long live decisions"><TableHeader><TableRow>{['Contract', 'Decision', 'Entry filter', 'Exit filter', 'Evaluated hour (UTC)', 'Price', 'Tracked entry', 'Gross return', 'Actions'].map(label => <TableHead key={label}>{label}</TableHead>)}</TableRow></TableHeader>
            <TableBody>{visible.slice(contractPage*50, contractPage*50+50).map(row => <TableRow key={row.instrument}>
              <TableCell>{row.instrument}</TableCell><TableCell title={row.reason}><Badge variant={row.action === 'Unknown' ? 'outline' : 'secondary'}>{row.btcExit ? 'BTC risk · ' : forming ? 'Preview · ' : ''}{row.action}</Badge></TableCell>
              <TableCell>{row.position ? <span className="text-xs text-muted-foreground">Inactive while holding</span> : <FilterTruthBadge value={row.entry} />}</TableCell><TableCell>{row.position ? <FilterTruthBadge value={row.exit} /> : <span className="text-xs text-muted-foreground">Inactive while flat</span>}</TableCell><TableCell>{researchTime(row.hour)}</TableCell><TableCell>{longPrice(row.price)}</TableCell>
              <TableCell>{longPrice(row.position?.entryPrice)}</TableCell><TableCell>{row.position ? researchPercent(longReturn(row.price, row.position.entryPrice)) : '—'}</TableCell>
              <TableCell><div className="flex items-center gap-1"><Button variant="ghost" size="sm" aria-label={'Explain ' + row.instrument + ' decision'} disabled={pending} onClick={() => void inspect(row)}>Explain</Button>
                <Button variant="ghost" size="icon" aria-label={'Chart ' + row.instrument} onClick={() => setChart(row.instrument)}><ChartNoAxesCombined aria-hidden="true" /></Button>
                <Button variant="outline" size="sm" disabled={pending} onClick={() => beginRecord(row.position ? 'close' : 'open', row.instrument, row.price)}>{row.position ? 'Record exit' : 'Record entry'}</Button></div></TableCell>
            </TableRow>)}</TableBody></Table>
          {!visible.length && <Empty><EmptyHeader><EmptyTitle>{decisions.length ? 'No matching decision rows' : 'Waiting for hourly market data'}</EmptyTitle><EmptyDescription>Keep monitoring running, or choose another view.</EmptyDescription></EmptyHeader></Empty>}
          <div className="flex items-center gap-3"><Button variant="outline" disabled={contractPage === 0} onClick={() => setPage(contractPage-1)}>Previous contracts</Button><span className="text-xs text-muted-foreground">{visible.length ? contractPage*50+1 : 0}–{Math.min(visible.length,contractPage*50+50)} / {visible.length}</span><Button variant="outline" disabled={(contractPage+1)*50 >= visible.length} onClick={() => setPage(contractPage+1)}>Next contracts</Button></div>
        </>}
      </TabsContent>
      <TabsContent value="positions" className="flex flex-col gap-4">
        <h2 className="font-semibold">Open Longs · {selected?.name ?? 'Choose a strategy'}</h2><p className="text-xs text-muted-foreground">These are your manual tracking records. Saved exit rules use each record's entry price and time. Missing data or restarting the app preserves the position.</p>
        <Table aria-label="Tracked Long positions"><TableHeader><TableRow>{['Contract', 'Entry time (UTC)', 'Actual entry', 'Entry revision', 'Actions'].map(label => <TableHead key={label}>{label}</TableHead>)}</TableRow></TableHeader><TableBody>{open.slice(openIndex*50,openIndex*50+50).map(position => <TableRow key={position.id}><TableCell>{position.instrument}</TableCell><TableCell>{researchTime(position.enteredAt)}</TableCell><TableCell>{longPrice(position.entryPrice)}</TableCell><TableCell>v{position.strategy.revision} · Current exit v{selected?.revision}</TableCell><TableCell><div className="flex gap-2"><Button variant="outline" onClick={() => beginRecord('close', position.instrument, decisions.find(d => d.instrument === position.instrument)?.price)}>Record exit</Button><Button variant="ghost" aria-label={'Remove tracking ' + position.instrument} onClick={() => setConfirm({ kind: 'remove', position })}><Trash2 aria-hidden="true" /></Button></div></TableCell></TableRow>)}</TableBody></Table>
        <div className="flex items-center gap-3"><Button variant="outline" disabled={openIndex === 0} onClick={() => setOpenPage(openIndex-1)}>Previous open positions</Button><span className="text-xs text-muted-foreground">{open.length ? openIndex*50+1 : 0}–{Math.min(open.length,openIndex*50+50)} / {open.length}</span><Button variant="outline" disabled={(openIndex+1)*50 >= open.length} onClick={() => setOpenPage(openIndex+1)}>Next open positions</Button></div>
        <h2 className="font-semibold">Recorded exits · All strategies</h2><Table aria-label="Recorded Long exits"><TableHeader><TableRow>{['Strategy', 'Contract', 'Entry', 'Exit', 'Actual entry', 'Actual exit', 'Gross return', 'Rule revisions'].map(label => <TableHead key={label}>{label}</TableHead>)}</TableRow></TableHeader><TableBody>{tracked.slice(exitIndex*50,exitIndex*50+50).map(position => <TableRow key={position.id}><TableCell>{position.strategy.name}</TableCell><TableCell>{position.instrument}</TableCell><TableCell>{researchTime(position.enteredAt)}</TableCell><TableCell>{researchTime(position.exitedAt!)}</TableCell><TableCell>{longPrice(position.entryPrice)}</TableCell><TableCell>{longPrice(position.exitPrice)}</TableCell><TableCell>{researchPercent(longReturn(position.exitPrice,position.entryPrice))}</TableCell><TableCell>Entry v{position.strategy.revision} · Exit {position.exitStrategy ? "v"+position.exitStrategy.revision : "—"}</TableCell></TableRow>)}</TableBody></Table>
        <div className="flex items-center gap-3"><Button variant="outline" disabled={exitIndex === 0} onClick={() => setExitPage(exitIndex-1)}>Previous recorded exits</Button><span className="text-xs text-muted-foreground">{tracked.length ? exitIndex*50+1 : 0}–{Math.min(tracked.length,exitIndex*50+50)} / {tracked.length}</span><Button variant="outline" disabled={(exitIndex+1)*50 >= tracked.length} onClick={() => setExitPage(exitIndex+1)}>Next recorded exits</Button></div>
      </TabsContent>
    </Tabs>
    <Dialog open={Boolean(record)} onOpenChange={open => { if (!open) setRecord(null) }}><DialogContent className="scale-(--market-list-scale)">
      <DialogHeader><DialogTitle>{record?.kind === 'open' ? 'Record actual Long entry' : 'Record actual Long exit'}</DialogTitle><DialogDescription>{record?.instrument} · {selected?.name}. This updates your tracking state after a manual trade.</DialogDescription></DialogHeader>
      <form onSubmit={e => { e.preventDefault(); void perform(async () => {
        if (!record || !selected) return
        const price = Number(record.price), timestamp = Date.parse(record.time + ':00Z')
        if (!Number.isFinite(price) || price <= 0 || !Number.isFinite(timestamp)) throw new Error('Enter a positive actual price and valid UTC time.')
        accept(await requestLong({ action: record.kind, strategyID: selected.id, instrument: record.instrument, price, timestamp })); accept(await requestLong({ action: 'evaluate', strategyID: selected.id, forming })); setRecord(null); setNotice('Actual trade recorded. The next refresh uses the updated position state.')
      }) }}><FieldGroup><Field><FieldLabel htmlFor="long-record-price">Actual execution price (USDT)</FieldLabel><Input id="long-record-price" inputMode="decimal" autoComplete="off" value={record?.price ?? ''} onChange={e => setRecord(current => current && { ...current, price: e.target.value })} /></Field>
        <Field><FieldLabel htmlFor="long-record-time">Execution time (UTC)</FieldLabel><Input id="long-record-time" type="datetime-local" value={record?.time ?? ''} onChange={e => setRecord(current => current && { ...current, time: e.target.value })} /><FieldDescription>Entry price and time are retained for position-based exit filters.</FieldDescription></Field></FieldGroup>
        {error && <p role="alert" className="mt-3 text-sm text-destructive">{error}</p>}<DialogFooter className="mt-4"><Button type="button" variant="outline" onClick={() => setRecord(null)}>Cancel</Button><Button type="submit" disabled={pending}><Check data-icon="inline-start" aria-hidden="true" />Save tracking record</Button></DialogFooter></form>
    </DialogContent></Dialog>
    <Dialog open={Boolean(detail)} onOpenChange={open => { if (!open) setDetail(null) }}><DialogContent className="flex max-h-[85vh] w-[min(calc(var(--market-list-layout-width)*0.9),80rem)] max-w-none scale-(--market-list-scale) flex-col sm:max-w-none">
      <DialogHeader><DialogTitle>{detail?.instrument} · {detail?.btcExit ? 'BTC risk · ' : ''}{detail?.action}</DialogTitle><DialogDescription>{detail?.reason} {detail && researchTime(detail.hour)} · {detail?.btcExit ? 'Confirmed BTC risk · reference hours shown below' : forming ? 'Forming-hour preview' : 'Completed hourly close'}</DialogDescription></DialogHeader>
      {detail && selected && <div className="flex min-h-0 flex-col gap-3 overflow-y-auto"><h3 className="font-semibold">Entry filter · {detail.position ? 'Inactive while holding' : 'Active while flat'}</h3>{detail.entryTraceJSON && <TraceNode trace={JSON.parse(detail.entryTraceJSON) as FilterTrace} config={parseFilterConfig(selected.entryJSON)} context={context} />}
        <h3 className="font-semibold">Exit filter · {detail.position ? 'Active while holding' : 'Inactive while flat'}</h3>{detail.exitTraceJSON && <TraceNode trace={JSON.parse(detail.exitTraceJSON) as FilterTrace} config={parseFilterConfig(selected.exitJSON)} context={context} />}</div>}
    </DialogContent></Dialog>
    <Dialog open={Boolean(confirm)} onOpenChange={open => { if (!open) setConfirm(null) }}><DialogContent className="scale-(--market-list-scale)"><DialogHeader><DialogTitle>{confirm?.kind === 'load' ? 'Replace this strategy draft?' : confirm?.kind === 'delete' ? 'Delete saved strategy?' : 'Remove this tracking record?'}</DialogTitle><DialogDescription>{confirm?.kind === 'load' ? 'Your unsaved entry and exit drafts will be replaced. Saved rules and tracked positions remain.' : confirm?.kind === 'delete' ? 'The saved strategy is removed. Frozen backtests and recorded exits retain their original rules. Open tracked Longs must be closed or removed first.' : 'Remove the manual record without inventing an execution or exit price.'}</DialogDescription></DialogHeader><DialogFooter><Button variant="outline" onClick={() => setConfirm(null)}>Keep</Button><Button variant={confirm?.kind === 'load' ? 'default' : 'destructive'} disabled={pending} onClick={() => void perform(async () => {
      if (!confirm) return
      if (confirm.kind === 'load') await choose(confirm.strategy ?? null)
      else if (confirm.kind === 'delete' && confirm.strategy) { accept(await requestLong({ action: 'delete', strategyID: confirm.strategy.id })); await choose(null) }
      else if (confirm.position) accept(await requestLong({ action: 'removeTracking', positionID: confirm.position.id }))
      setConfirm(null)
    })}>{confirm?.kind === 'load' ? 'Replace draft' : 'Remove'}</Button></DialogFooter></DialogContent></Dialog>
  </main></MarketListViewport>
}
