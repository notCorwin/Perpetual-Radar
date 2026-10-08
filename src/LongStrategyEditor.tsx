import { useEffect, useState } from 'react'
import { MarketFilters } from '@/MarketFilters'
import { FilterExplanation } from '@/FilterExplanation'
import { Field, FieldDescription, FieldLabel } from '@/components/ui/field'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { newRuleID, parseFilterConfig, type FilterLibraryPreferences, type FilterTruth, type NativeMarketRow } from '@/rule-engine'
import type { ResearchInputs } from '@/research-types'
import type { useStrategyFilter } from '@/use-strategy-filter'

export function LongStrategyEditor({ label, model, inputs, preferences, onPreferences, active, strategyID }: {
  label: 'Entry filter' | 'Exit filter'; model: ReturnType<typeof useStrategyFilter>; inputs: ResearchInputs; preferences: FilterLibraryPreferences
  onPreferences: (value: FilterLibraryPreferences) => Promise<void>; active: boolean; strategyID: string
}) {
  const [rows, setRows] = useState<NativeMarketRow[]>([]), [results, setResults] = useState<Record<string, FilterTruth>>({})
  const [revision, setRevision] = useState(0), [previewJSON, setPreviewJSON] = useState<string | null>(null)
  const [history, setHistory] = useState<{ pending: number; completed: number; error: string } | null>(null)
  const [explaining, setExplaining] = useState<string | null>(null), [sourceID, setSourceID] = useState('')
  useEffect(() => {
    if (!active || !model.lastValid) return
    let stopped = false, timer: number
    const token = newRuleID(), json = model.lastValid
    const refresh = async () => {
      try {
        const snapshot = await window.webkit.messageHandlers.radar.postMessage({ previewMarketFilters: { filtersJSON: json, token, atClose: true, strategyID } })
        if (stopped) return
        setRows(snapshot.rows); setResults(snapshot.filterResults); setRevision(snapshot.revision); setHistory(snapshot.historyProgress); setPreviewJSON(json)
      } catch (cause) { if (!stopped) setHistory({ pending: 0, completed: 0, error: cause instanceof Error ? cause.message : 'Cannot preview these rules.' }) }
      if (!stopped) timer = window.setTimeout(refresh, 2000)
    }
    void refresh(); return () => { stopped = true; window.clearTimeout(timer) }
  }, [active, model.lastValid, strategyID])
  const options = [{ id: 'radar', name: 'Current applied Radar rules', json: JSON.stringify(inputs.filters) }, ...inputs.combinations.map(c => ({ id: c.id, name: c.name, json: c.filterConfigJSON ?? c.filtersJSON }))]
  const expressions = { ...model.editor.expressionDrafts, ...model.compilation.expressions }
  return <section aria-label={label} className="flex flex-col gap-3" data-strategy-filter>
    <Field className="px-4"><FieldLabel>Start from existing filters</FieldLabel><Select value={sourceID} onValueChange={id => {
      const item = options.find(o => o.id === id)
      if (item) { model.setDraft(parseFilterConfig(item.json)); model.setEditor(current => ({ ...current, source: null, selectedRuleId: null, selectedIds: [] })); setSourceID(id) }
    }}><SelectTrigger aria-label={'Load ' + label.toLowerCase()}><SelectValue placeholder="Choose a saved combination…" /></SelectTrigger><SelectContent><SelectGroup>{options.map(o => <SelectItem key={o.id} value={o.id}>{o.name}</SelectItem>)}</SelectGroup></SelectContent></Select>
      <FieldDescription>{label === 'Entry filter' ? 'Checked while flat. Every supported Radar condition, formula and sequence is available.' : 'Checked while holding a Long. Add Long return (%), Long entry price or holding time alongside market conditions.'} Keep a filter for preview; Save strategy applies both together.</FieldDescription>
    </Field>
    <MarketFilters label={label} embedded atClose strategyID={strategyID} filters={model.filters} draft={model.draft} editor={model.editor} onEditorChange={model.setEditor} onDraftChange={model.setDraft} onApply={model.keep}
      combinations={[]} combinationId="" onSelectCombination={async () => {}} onSaveCombination={async () => { throw new Error('Save the strategy above.') }} onDeleteCombination={async () => {}}
      metrics={inputs.metrics} functions={inputs.functions ?? inputs.templates.map(t => t.name)} templates={inputs.templates} preferences={preferences} onPreferences={onPreferences}
      rows={rows} results={results} previewJSON={previewJSON} revision={revision} onExplain={setExplaining} units={model.compilation.units ?? {}} expressions={expressions} formula={model.compilation.formula ?? 'true'}
      diagnostics={model.compilation.diagnostics} valid={model.valid} compiling={model.compiling} requiredHours={model.compilation.requiredHours ?? 0}
      matches={Object.values(results).filter(v => v === 'true').length} total={rows.length} unknown={Object.values(results).filter(v => v === 'unknown').length} previewPending={previewJSON !== model.lastValid} history={history} />
    <FilterExplanation open={active && Boolean(explaining)} onOpenChange={open => { if (!open) setExplaining(null) }} instId={explaining} onSelect={setExplaining} rows={rows} results={results} filtersJSON={previewJSON} revision={revision}
      metrics={inputs.metrics} expressions={expressions} units={model.compilation.units ?? {}} templates={inputs.templates} atClose strategyID={strategyID} />
  </section>
}
