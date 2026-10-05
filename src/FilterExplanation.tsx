import { useEffect, useState } from "react"
import { Check, CircleHelp, ScanSearch, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Command, CommandEmpty, CommandInput, CommandItem, CommandList } from "@/components/ui/command"
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { FieldError } from "@/components/ui/field"
import { Spinner } from "@/components/ui/spinner"
import { cn } from "@/lib/utils"
import { previewResponseIsCurrent, newRuleID, type FilterTrace, type FilterTruth, type NativeMarketRow } from "@/rule-engine"

function Truth({ value }: { value: FilterTruth | undefined }) {
  const Icon = value === "true" ? Check : value === "false" ? X : CircleHelp
  return <Badge variant="outline" className={cn(value === "true" ? "text-positive" : value === "false" ? "text-destructive" : "text-muted-foreground")}><Icon aria-hidden="true" />{value === "true" ? "True" : value === "false" ? "False" : "Unknown"}</Badge>
}

function TraceNode({ trace }: { trace: FilterTrace }) {
  return <details open className="rounded-lg border p-3">
    <summary className="flex cursor-pointer list-none items-center gap-2 text-sm"><Truth value={trace.result} /><span className="min-w-0 flex-1 break-words font-medium">{trace.label}</span><time className="shrink-0 text-xs text-muted-foreground" dateTime={new Date(trace.hour).toISOString()}>{new Date(trace.hour).toLocaleString("en-US", { month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit" })}</time></summary>
    <div className="mt-2 flex flex-col gap-2">
      {Object.keys(trace.readings).length > 0 && <dl className="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)] gap-x-4 gap-y-1 text-xs tabular-nums">{Object.entries(trace.readings).map(([name, value]) => <div key={name} className="contents"><dt className="break-words text-muted-foreground">{name}</dt><dd className="break-words text-right">{value}</dd></div>)}</dl>}
      {trace.reason && <p className="text-xs text-muted-foreground">{trace.reason}</p>}
      {trace.eventHours.length > 0 && <p className="text-xs text-muted-foreground">Event path: {trace.eventHours.map(hour => new Date(hour).toLocaleString("en-US")).join(" → ")}</p>}
      {trace.children.length > 0 && <div className="ml-2 flex flex-col gap-2 border-l pl-3">{trace.children.map((child, index) => <TraceNode key={`${child.id}:${child.hour}:${index}`} trace={child} />)}</div>}
    </div>
  </details>
}

type Props = { open: boolean; onOpenChange: (open: boolean) => void; instId: string | null; onSelect: (id: string) => void; rows: NativeMarketRow[]; results: Record<string, FilterTruth>; filtersJSON: string | null; revision: number }
export function FilterExplanation({ open, onOpenChange, instId, onSelect, rows, results, filtersJSON, revision }: Props) {
  const id = instId ?? rows[0]?.instId
  const key = `${id ?? ""}|${filtersJSON ?? ""}`
  const [detail, setDetail] = useState<{ key: string; revision: number; trace: FilterTrace | null; error: string } | null>(null)
  const trace = detail?.key === key ? detail.trace : null
  const error = detail?.key === key && detail.revision >= revision ? detail.error : ""
  const loading = open && Boolean(id && filtersJSON) && (detail?.key !== key || detail.revision < revision)
  useEffect(() => {
    if (!open || !id || !filtersJSON) return
    let stopped = false
    const token = newRuleID()
    void window.webkit.messageHandlers.radar.postMessage({ explainMarketFilters: { instId: id, filtersJSON, token } }).then(response => {
      if (!stopped && response.instId === id && previewResponseIsCurrent(response, token, revision)) setDetail({ key, revision: response.revision, trace: response.trace, error: "" })
    }).catch(cause => { if (!stopped) setDetail(previous => ({ key, revision, trace: previous?.key === key ? previous.trace : null, error: cause instanceof Error ? cause.message : "Cannot explain this contract." })) })
    return () => { stopped = true }
  }, [open, id, filtersJSON, revision, key])
  return <Dialog open={open} onOpenChange={onOpenChange}><DialogContent className="flex h-[min(85vh,60rem)] max-w-[min(92vw,84rem)] flex-col gap-3 sm:max-w-[min(92vw,84rem)]">
    <DialogHeader><DialogTitle>Market rule explanations</DialogTitle><DialogDescription>Inspect matching, unmatched, and unknown markets using the current valid preview. Times use your local time zone.</DialogDescription></DialogHeader>
    <div className="grid min-h-0 flex-1 grid-cols-[18rem_minmax(0,1fr)] gap-4">
      <Command className="border"><CommandInput placeholder="Search all contracts…" /><CommandList className="max-h-none"><CommandEmpty>No contracts found.</CommandEmpty>{rows.map(row => <CommandItem key={row.instId} value={row.instId} onSelect={() => onSelect(row.instId)} className={cn(id === row.instId && "bg-accent")}><span className="flex-1">{row.instId.replace(/-USDT-SWAP$/, "")}</span><Truth value={results[row.instId]} /></CommandItem>)}</CommandList></Command>
      <section aria-label="Rule decision details" className="min-h-0 overflow-y-auto">
        <div className="mb-3 flex items-center gap-2"><ScanSearch className="size-4" aria-hidden="true" /><span className="font-medium">{id ?? "Waiting for markets"}</span><Truth value={trace?.result ?? (id ? results[id] : undefined)} /><Button variant="ghost" size="sm" className="ml-auto" onClick={() => onOpenChange(false)}>Done</Button></div>
        {loading && <p className="flex items-center gap-2 text-sm text-muted-foreground"><Spinner aria-hidden="true" />Explaining hourly rules…</p>}
        {error && <FieldError role="alert">{error}</FieldError>}
        {trace && <TraceNode trace={trace} />}
      </section>
    </div>
  </DialogContent></Dialog>
}
