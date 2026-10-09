import { useEffect, useRef, useState } from 'react'
import { Camera } from 'lucide-react'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Spinner } from '@/components/ui/spinner'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { TraceNode } from '@/FilterExplanation'
import { MathHeading } from '@/MathHeading'
import { ResearchChart } from '@/ResearchChart'
import { longPrice } from '@/long-decisions'
import { parseFilterConfig, type FilterTrace } from '@/rule-engine'
import { requestResearch, researchPercent, researchTime, type DataManifest, type ResearchInputs, type StudyReport } from '@/research-types'
import { suiteRules, type SuiteAccount, type SuiteCurvePoint, type SuiteTrade } from '@/suite-types'

const number = (n?: number) => n == null ? '—' : n.toLocaleString('en-US', { maximumFractionDigits: 2 })
const sign = (n?: number) => n == null || n === 0 ? '' : n > 0 ? 'text-positive' : 'text-destructive'
const accountKey = (a: SuiteAccount) => [a.profileID,a.instrument,a.model].join('|')
const headings = [
  ['n', 'Eligible closed trades'], ['n_{excluded}', 'Incomplete, uncertain or split-boundary trades; open trades are listed separately'],
  ['p_{win}', 'Win rate'], ['\\overline{R}', 'Mean allocated-margin return'], ['\\frac{\\overline{R}_{win}}{|\\overline{R}_{loss}|}', 'Average payoff ratio'],
  ['\\frac{\\sum P_{win}}{|\\sum P_{loss}|}', 'Profit Factor'], ['\\sum P', 'Profit (USDT)'], ['\\overline{t}', 'Mean holding hours; OHLC liquidations show a duration range'],
  ['MFE', 'Mean favorable price excursion'], ['MAE', 'Mean adverse price excursion'], ['n_{liq}', 'Liquidations'], ['CI_{95\\%}', 'Deterministic weekly confidence interval'],
] as const

function EquityCurve({ account, studyID }: { account: SuiteAccount; studyID: string }) {
  const [points, setPoints] = useState<SuiteCurvePoint[]>([]), [error, setError] = useState(''), [loading, setLoading] = useState(false)
  const [inspection, setInspection] = useState<number | null>(null), [copied, setCopied] = useState(false)
  const section = useRef<HTMLElement>(null)
  useEffect(() => {
    let stopped = false
    void (async () => {
      setLoading(true); setError(''); setPoints([]); setInspection(null)
      try {
        const all: SuiteCurvePoint[] = []
        let count = Infinity
        while (all.length < count && !stopped) {
          const result = await requestResearch({ action: 'suiteCurve', studyID, profileID: account.profileID, instrument: account.instrument, model: account.model, offset: all.length })
          if (!result.curve?.length) break
          all.push(...result.curve); count = result.count ?? all.length
        }
        if (!stopped) setPoints(all)
      } catch (cause) { if (!stopped) setError(String(cause)) }
      finally { if (!stopped) setLoading(false) }
    })()
    return () => { stopped = true }
  }, [studyID, account.profileID, account.instrument, account.model])
  useEffect(() => { if (!copied) return; const timer = window.setTimeout(() => setCopied(false),1500); return () => window.clearTimeout(timer) }, [copied])
  const capture = async () => {
    const rect = section.current?.getBoundingClientRect(); if (!rect) return
    try {
      const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1
      const context = canvas.getContext('2d'); if (!context) throw new Error('Cannot resolve snapshot background.')
      context.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--chart-snapshot-background'); context.fillRect(0,0,1,1)
      const backgroundRGB = Array.from(context.getImageData(0,0,1,1).data).slice(0,3).map(v => v/255)
      await window.webkit.messageHandlers.radar.postMessage({ captureChart: { x: rect.x,y: rect.y,width: rect.width,height: rect.height,backgroundRGB } }); setCopied(true)
    } catch (cause) { setError(String(cause)) }
  }
  const width = 1200, right = 1020, top = 20, bottom = 215, ddTop = 265, ddBottom = 345
  const limits = points.reduce((r,p) => ({min:Math.min(r.min,p.equity),max:Math.max(r.max,p.equity),dd:Math.max(r.dd,p.drawdown)}),{min:account.initial,max:account.initial,dd:0.01})
  const {min,max} = limits, span = max-min || Math.max(1,max*0.01), maxDD = limits.dd
  const start = points[0]?.timestamp ?? 0, end = points.at(-1)?.timestamp ?? start+1
  const x = (p: SuiteCurvePoint) => 12+(p.timestamp-start)/Math.max(1,end-start)*(right-12)
  const y = (p: SuiteCurvePoint) => bottom-(p.equity-min)/span*(bottom-top)
  const dy = (p: SuiteCurvePoint) => ddTop+p.drawdown/maxDD*(ddBottom-ddTop)
  // Preserve each bucket's extrema so the plotted drawdowns are not averaged away.
  const plotted: SuiteCurvePoint[] = []
  const bucket = Math.max(1,Math.ceil(points.length/500))
  for (let i=0;i<points.length;i+=bucket) {
    const chunk = points.slice(i,i+bucket)
    const ordered = [chunk[0],chunk.reduce((a,b) => a.equity<b.equity?a:b),chunk.reduce((a,b) => a.equity>b.equity?a:b),chunk.reduce((a,b) => a.drawdown>b.drawdown?a:b),chunk.at(-1)!].sort((a,b) => a.timestamp-b.timestamp)
    ordered.forEach(p => { if (plotted.at(-1)?.timestamp !== p.timestamp) plotted.push(p) })
  }
  const active = points[inspection ?? points.length-1], last = plotted.at(-1)
  return <section className="flex flex-col gap-2" aria-label="Independent account curve">
    <div className="flex items-center gap-3"><h3 className="font-semibold">{account.instrument} · {account.model}</h3><Badge variant="outline">{account.status}</Badge><span className="flex-1 text-xs text-muted-foreground">{account.profileName} · Hourly closing equity</span><Button variant="outline" size="sm" disabled={!points.length} onClick={() => void capture()}><Camera data-icon="inline-start" aria-hidden="true" />{copied?'Copied':'Copy chart'}</Button></div>
    {error && <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>}
    {loading ? <Spinner aria-label="Loading account curve" /> : <section ref={section} data-surface="panel" className="rounded-lg border bg-chart-surface p-3">
      <div className="flex items-center gap-4 text-xs"><span>Solid: Equity (USDT)</span><span>Dashed: Drawdown</span><span className="flex-1" /><span>{active?researchTime(active.timestamp):'No available closing valuations'}</span><span>{number(active?.equity)} USDT</span><span>−{researchPercent(active?.drawdown)}</span><span>{active?.direction ?? 'Flat'}{active?.uncertain?' · Uncertain':''}</span></div>
      {last && <svg viewBox={'0 0 '+width+' 370'} className="w-full select-none focus-visible:outline-2 focus-visible:outline-ring" role="img" tabIndex={0} aria-label="Hourly equity and drawdown. Left and right inspect full-resolution closing values." onPointerMove={e => {
        const rect=e.currentTarget.getBoundingClientRect(), target=start+Math.max(0,Math.min(1,((e.clientX-rect.left)/rect.width*width-12)/(right-12)))*(end-start)
        let nearest=0; points.forEach((p,i) => { if (Math.abs(p.timestamp-target)<Math.abs(points[nearest].timestamp-target)) nearest=i }); setInspection(nearest)
      }} onPointerLeave={() => setInspection(null)} onKeyDown={e => { if (e.key==='ArrowLeft'||e.key==='ArrowRight') { e.preventDefault(); setInspection(i => Math.max(0,Math.min(points.length-1,(i ?? points.length-1)+(e.key==='ArrowLeft'?-1:1)))) } if(e.key==='Escape')setInspection(null) }}>
        <line x1={12} x2={right} y1={bottom} y2={bottom} stroke="var(--border)" />
        <polyline fill="none" stroke="var(--chart-1)" strokeWidth={2} points={plotted.map(p=>x(p)+','+y(p)).join(' ')} />
        <g fill="var(--chart-1)"><line x1={x(last)} y1={y(last)} x2={right+8} y2={y(last)} stroke="var(--chart-1)" /><text x={right+12} y={y(last)+4} className="text-xs">{number(last.equity)} USDT</text></g>
        <polyline fill="none" stroke="var(--destructive)" strokeWidth={2} strokeDasharray="5 3" points={plotted.map(p=>x(p)+','+dy(p)).join(' ')} />
        <g fill="var(--destructive)"><line x1={x(last)} y1={dy(last)} x2={right+8} y2={dy(last)} stroke="var(--destructive)" strokeDasharray="5 3" /><text x={right+12} y={dy(last)+4} className="text-xs">−{researchPercent(last.drawdown)}</text></g>
        {inspection!=null&&active&&<line x1={x(active)} x2={x(active)} y1={top} y2={ddBottom} stroke="var(--muted-foreground)" strokeDasharray="2 4" />}
        <g fill="var(--muted-foreground)" className="text-xs"><text x={12} y={367}>{researchTime(start)}</text><text x={right} y={367} textAnchor="end">{researchTime(end)}</text></g>
      </svg>}
    </section>}
    {account.reason && <p className="text-xs text-muted-foreground">{account.reason} Last available equity is displayed; the missing range is not compounded.</p>}
  </section>
}

export function SuiteStudyResults({ report, inputs, manifest, active = true }: { report: StudyReport; inputs: ResearchInputs; manifest: DataManifest | null; active?: boolean }) {
  const stats = report.suite!, [scope,setScope] = useState('all'), [accountID,setAccountID] = useState('')
  const [trades,setTrades] = useState<SuiteTrade[]>([]), [count,setCount] = useState(0), [offset,setOffset] = useState(0), [error,setError] = useState('')
  const [trade,setTrade] = useState<SuiteTrade|null>(null), [anchor,setAnchor] = useState('entry')
  const account = stats.accounts.find(a=>accountKey(a)===accountID) ?? stats.accounts[0]
  const page = async (start: number) => {
    try { const result=await requestResearch({action:'suiteTrades',studyID:report.studyID,offset:start}); setTrades(result.suiteTrades??[]); setCount(result.count??0);setOffset(start);setError('');return result.suiteTrades??[] }
    catch(cause){setError(String(cause));return []}
  }
  useEffect(() => {
    let stopped=false
    void requestResearch({action:'suiteTrades',studyID:report.studyID,offset:0}).then(result=>{if(!stopped){setTrades(result.suiteTrades??[]);setCount(result.count??0);setOffset(0);setTrade(null);setAccountID('')}}).catch(cause=>{if(!stopped)setError(String(cause))})
    return()=>{stopped=true}
  },[report.studyID])
  const navigate = async(step:number)=>{if(!trade)return;const index=trades.findIndex(t=>t.id===trade.id)+step;if(index>=0&&index<trades.length)setTrade(trades[index]);else{const next=offset+(step>0?50:-50);if(next>=0&&next<count){const rows=await page(next);setTrade(step>0?rows[0]:rows.at(-1)??null)}}setAnchor('entry')}
  const exportCSV = async(kind:string)=>{try{await requestResearch({action:'export',studyID:report.studyID,kind});setError('')}catch(cause){setError(String(cause))}}
  const rows=stats.summaries.filter(s=>scope==='all'?!s.instrument&&!s.direction&&!s.split:scope==='direction'?s.direction:scope==='instrument'?s.instrument:s.split)
  const context={metrics:inputs.metrics,expressions:{},units:{},templates:inputs.templates}
  const event=trade&&(anchor==='exit'&&trade.exitEvent?trade.exitEvent:trade.entryEvent)
  const profile=trade&&report.spec.strategySnapshots?.find(p=>p.id===trade.profileID)
  const frozenRules=profile?suiteRules(profile):[]
  return <section className="flex flex-col gap-4" aria-label="Multi-direction study results">
    {error&&<Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>}
    <div className="flex items-center gap-3"><ToggleGroup type="single" variant="outline" value={scope} onValueChange={v=>{if(v)setScope(v)}} aria-label="Cycle summary grouping"><ToggleGroupItem value="all">By version</ToggleGroupItem><ToggleGroupItem value="direction">By direction</ToggleGroupItem><ToggleGroupItem value="instrument">By contract</ToggleGroupItem><ToggleGroupItem value="split">Time splits</ToggleGroupItem></ToggleGroup><span className="flex-1" /><Button variant="outline" onClick={()=>void exportCSV('events')}>Export trades CSV</Button><Button variant="outline" onClick={()=>void exportCSV('equity')}>Export equity CSV</Button></div>
    <Table aria-label="Cycle study statistics"><TableHeader><TableRow><TableHead>Version / Account / Group</TableHead>{headings.map(([formula,label])=><TableHead key={label}><MathHeading formula={formula} label={label}/></TableHead>)}</TableRow></TableHeader><TableBody>{rows.map(s=><TableRow key={[s.profileID,s.model,s.instrument,s.direction,s.split].join('|')}><TableCell>{s.profileName}<div className="text-xs text-muted-foreground">{s.model} · {s.instrument??s.direction??s.split??'All eligible trades'}</div></TableCell><TableCell>{s.count}</TableCell><TableCell>{s.excluded}<div className="whitespace-nowrap text-xs text-muted-foreground">{s.open} Open · {s.incomplete} Incomplete<br />{s.uncertain} Uncertain · {s.crossSplit} Cross-split · {s.purged} Purged</div></TableCell><TableCell>{researchPercent(s.winRate)}</TableCell><TableCell className={sign(s.mean)}>{researchPercent(s.mean)}</TableCell><TableCell>{s.payoffInfinite?'∞':number(s.payoffRatio)}</TableCell><TableCell>{s.profitFactorInfinite?'∞':number(s.profitFactor)}</TableCell><TableCell className={sign(s.profit)}>{number(s.profit)}</TableCell><TableCell>{s.averageHoursLow!=null&&s.averageHoursLow!==s.averageHours?number(s.averageHoursLow)+'–':''}{number(s.averageHours)}h</TableCell><TableCell className="text-positive">{researchPercent(s.mfe)}</TableCell><TableCell className="text-destructive">{researchPercent(s.mae)}</TableCell><TableCell>{s.liquidations}</TableCell><TableCell>{s.intervalLow==null?'—':researchPercent(s.intervalLow)+' to '+researchPercent(s.intervalHigh)}</TableCell></TableRow>)}</TableBody></Table>
    <p className="text-xs text-muted-foreground">Margin returns and monetary Profit Factor use separate Gross and Net simulations. Open, incomplete, uncertain and cross-split trades are listed separately and excluded from primary statistics. Versions share frozen inputs and common evaluable entry hours. Confidence intervals require 30 closed trades and 8 UTC weeks.</p>
    <details><summary className="font-medium">Independent capital accounts</summary><Table aria-label="Cycle capital accounts"><TableHeader><TableRow><TableHead>Version / Contract</TableHead><TableHead>Model</TableHead><TableHead>Initial USDT</TableHead><TableHead>Ending equity USDT</TableHead><TableHead><MathHeading formula="R_{equity}" label="Account equity return"/></TableHead><TableHead><MathHeading formula="DD_{max}" label="Hourly close maximum drawdown"/></TableHead><TableHead>Coverage / Position</TableHead></TableRow></TableHeader><TableBody>{stats.accounts.map(a=><TableRow key={accountKey(a)}><TableCell>{a.profileName}<div>{a.instrument}</div></TableCell><TableCell>{a.model}</TableCell><TableCell>{number(a.initial)}</TableCell><TableCell>{number(a.endingEquity)}</TableCell><TableCell className={sign(a.returnValue)}>{researchPercent(a.returnValue)}</TableCell><TableCell>{researchPercent(a.maxDrawdown)}{a.maxDrawdown==null&&<div className="text-xs text-muted-foreground">Observed {researchPercent(a.observedDrawdown)}</div>}</TableCell><TableCell><Badge variant="outline">{a.status} · {a.openDirection??'Flat'}</Badge><div className="text-xs text-muted-foreground">{a.reason}</div></TableCell></TableRow>)}</TableBody></Table></details>
    <Select value={account?accountKey(account):''} onValueChange={setAccountID}><SelectTrigger aria-label="Independent curve account"><SelectValue placeholder="Choose an account…"/></SelectTrigger><SelectContent><SelectGroup>{stats.accounts.map(a=><SelectItem key={accountKey(a)} value={accountKey(a)}>{a.profileName} · {a.instrument} · {a.model}</SelectItem>)}</SelectGroup></SelectContent></Select>
    {account&&<EquityCurve account={account} studyID={report.studyID}/>}
    <h3 className="font-semibold">All trades · Long and Short</h3>
    <Table aria-label="Cycle backtest trades"><TableHeader><TableRow><TableHead>Version / Contract</TableHead><TableHead>Model / Direction</TableHead><TableHead>Entry (UTC) / Price</TableHead><TableHead>Exit (UTC) / Price</TableHead><TableHead>Status / Hold</TableHead><TableHead>Margin / Quantity</TableHead><TableHead>Profit USDT</TableHead><TableHead><MathHeading formula="R_{margin}" label="Allocated margin return"/></TableHead><TableHead><MathHeading formula="R_{price}" label="Directional Signed Relative Change"/></TableHead><TableHead>MFE / MAE</TableHead><TableHead>Fees / Funding USDT</TableHead><TableHead>Evidence</TableHead></TableRow></TableHeader><TableBody>{trades.map(t=><TableRow key={t.id}><TableCell>{t.profileName}<div>{t.instrument}</div></TableCell><TableCell>{t.model}<div>{t.direction==='Long'?'↑ Long':'↓ Short'}</div></TableCell><TableCell>{researchTime(t.entryTime)}<div>{longPrice(t.entryPrice)}</div></TableCell><TableCell>{t.exitTime==null?'Open':t.liquidationFrom!=null?researchTime(t.liquidationFrom)+' → '+researchTime(t.liquidationThrough!):researchTime(t.exitTime)}<div>{longPrice(t.exitPrice)}</div></TableCell><TableCell><Badge variant="outline">{t.status}</Badge>{t.liquidationFrom!=null&&<div>Liquidated · Hour interval</div>}<div>{t.holdingHoursHigh==null?'Open':t.holdingHoursLow!==t.holdingHoursHigh?number(t.holdingHoursLow)+'–'+number(t.holdingHoursHigh)+'h':number(t.holdingHoursHigh)+'h'}</div></TableCell><TableCell>{number(t.margin)}<div>{longPrice(t.quantity)}</div></TableCell><TableCell className={sign(t.profit)}>{number(t.profit)}</TableCell><TableCell className={sign(t.returnValue)}>{researchPercent(t.returnValue)}</TableCell><TableCell className={sign(t.priceReturn)}>{researchPercent(t.priceReturn)}</TableCell><TableCell><span className="text-positive">{t.mfeIncomplete?'Unknown':researchPercent(t.mfe)}</span><div className="text-destructive">{t.maeIncomplete?'Unknown':researchPercent(t.mae)}</div></TableCell><TableCell>{number(t.fees)}<div>{number(t.funding)}</div></TableCell><TableCell><Button variant="ghost" size="sm" aria-label={'Inspect '+t.direction+' cycle trade '+t.instrument} onClick={()=>{setTrade(t);setAnchor('entry')}}>Inspect trade</Button><p className="text-xs text-muted-foreground">{t.entryEvent.split}{t.crossesSplit?' · Crosses split':''}{t.uncertain?' · Uncertain':''}</p><p className="max-w-56 text-xs text-muted-foreground">{t.reason}</p></TableCell></TableRow>)}</TableBody></Table>
    <div className="flex items-center gap-3"><Button variant="outline" disabled={offset===0} onClick={()=>void page(Math.max(0,offset-50))}>Previous trades</Button><span className="text-xs text-muted-foreground">{count?offset+1:0}–{Math.min(count,offset+trades.length)} / {count}</span><Button variant="outline" disabled={offset+50>=count} onClick={()=>void page(offset+50)}>Next trades</Button></div>
    <Dialog open={active && Boolean(trade)} onOpenChange={open=>{if(!open)setTrade(null)}}><DialogContent className="flex h-[min(calc(var(--market-list-layout-height)*0.94),80rem)] w-[min(calc(var(--market-list-layout-width)*0.94),100rem)] max-w-none scale-(--market-list-scale) flex-col sm:max-w-none"><DialogHeader><DialogTitle>{trade?.instrument} · {trade?.direction} · {trade?.model}</DialogTitle><DialogDescription>{trade?.profileName} · Frozen entry and exit evidence · {trade?.status}</DialogDescription></DialogHeader>
      {trade&&event&&<div className="flex min-h-0 flex-col gap-4 overflow-y-auto"><ToggleGroup type="single" variant="outline" value={anchor} onValueChange={v=>{if(v)setAnchor(v)}} aria-label="Cycle trade chart anchor"><ToggleGroupItem value="entry">Entry chart</ToggleGroupItem><ToggleGroupItem value="exit" disabled={!trade.exitEvent}>Exit chart</ToggleGroupItem></ToggleGroup><ResearchChart key={event.id} event={event} onNavigate={s=>void navigate(s)}/>
        <h3 className="font-semibold">{anchor==='entry'?'Entry signal close':'Exit signal close'} · All four phases and Universe</h3>
        {(JSON.parse(event.traceJSON) as FilterTrace).children.map((trace,i)=><div key={trace.id}><h4 className="font-medium">{frozenRules[i]?.name}</h4><TraceNode trace={trace} config={parseFilterConfig(frozenRules[i]?.filtersJSON)} context={context}/></div>)}
        {trade.liquidationFrom!=null&&<Alert variant="warning"><AlertDescription>Simplified isolated liquidation during {researchTime(trade.liquidationFrom)} → {researchTime(trade.liquidationThrough!)}. The threshold or opening gap determines the price; no minute-level trigger is inferred.</AlertDescription></Alert>}
        {(trade.uncertain||trade.crossesSplit||trade.entryEvent.split==='Purged')&&<Alert variant="warning"><AlertDescription>This trade is excluded from primary statistics because of missing rule inputs or a split boundary.</AlertDescription></Alert>}
        <details><summary>Frozen rules, capital and source provenance</summary><p className="break-all text-xs text-muted-foreground">{manifest?.digest} · {manifest?.engine}</p><pre className="whitespace-pre-wrap text-xs">{JSON.stringify({profile,execution:report.spec.execution,capital:report.spec.capital,costs:report.spec.costs},null,2)}</pre>{manifest?.sources.filter(s=>[...trade.entryEvent.sources,...(trade.exitEvent?.sources??[])].includes(s.id)).map(s=><p key={s.id} className="break-all text-xs">{s.kind} · {s.url} · {s.rawHash??'—'}</p>)}</details>
      </div>}
    </DialogContent></Dialog>
  </section>
}
