import { useRef, useState } from "react"
import { Check, Filter, GripVertical, Plus, RotateCcw, Save, Trash2, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/components/ui/empty"
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel, FieldLegend, FieldSet } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectGroup, SelectItem, SelectLabel, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Spinner } from "@/components/ui/spinner"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { cn } from "@/lib/utils"
import {
  FILTER_FIELDS, FILTER_GROUPS, FILTER_OPERATOR_LABELS, FILTER_PRESETS, describeFilterRule, emptyMarketFilters,
  makeFilterRule, marketFilterPreset, operatorsFor, parseMarketFilters, previewMarketFilters, reorderFilterRules, requiresFilterValue, validateFilterRule,
  type FilterField, type FilterOperator, type FilterRule, type MarketFilterCombination, type MarketFilters as FilterConfig,
} from "@/market-filters"

type Props = {
  filters: FilterConfig
  draft: FilterConfig | null
  onDraftChange: (draft: FilterConfig | null) => void
  onApply: (filters: FilterConfig) => Promise<void>
  combinations: MarketFilterCombination[]
  combinationId: string
  onSelectCombination: (id: string) => Promise<void>
  onSaveCombination: (name: string, filters: FilterConfig) => Promise<MarketFilterCombination>
  onDeleteCombination: (id: string) => Promise<void>
  matches: number
  total: number
}

type ReorderControls = {
  draggingId: string | null
  disabled: boolean
  start: (id: string) => void
  end: () => void
  move: (id: string, direction: -1 | 1) => void
}

function FilterInsertionLine({ atEnd = false }: { atEnd?: boolean }) {
  return <div aria-hidden="true" data-filter-insertion-line className={cn("pointer-events-none absolute inset-x-0 z-10 h-0.5 rounded-full bg-primary", atEnd ? "-bottom-1 translate-y-1/2" : "-top-1 -translate-y-1/2")} />
}

function FilterCondition({ rule, index, onChange, onRemove, showError, reorder }: {
  rule: FilterRule; index: number; onChange: (rule: FilterRule) => void; onRemove: () => void; showError: boolean; reorder: ReorderControls
}) {
  const definition = FILTER_FIELDS[rule.field]
  const error = showError ? validateFilterRule(rule) : null
  const valueId = `filter-value-${rule.id}`
  const errorId = `filter-error-${rule.id}`
  const dragging = reorder.draggingId === rule.id
  return <FieldSet data-filter-condition className={cn("rounded-lg border p-3", dragging && "opacity-50")} aria-label={`Condition ${index + 1}`}>
    <FieldLegend className="sr-only">Condition {index + 1}</FieldLegend>
    <FieldGroup className="grid grid-cols-[auto_18rem_13rem_20rem_minmax(0,1fr)_auto] items-start gap-3">
      <Button id={`filter-reorder-${rule.id}`} type="button" variant="ghost" size="icon" className="mt-6 cursor-grab active:cursor-grabbing" draggable={!reorder.disabled} aria-label={`Reorder condition ${index + 1}`} aria-describedby="filter-reorder-help" title="Drag to reorder. ArrowUp / ArrowDown moves the focused condition." onDragStart={event => {
        if (reorder.disabled) { event.preventDefault(); return }
        event.dataTransfer.effectAllowed = "move"
        event.dataTransfer.setData("text/plain", rule.id)
        const card = event.currentTarget.closest("[aria-label^='Condition ']")
        if (card) event.dataTransfer.setDragImage(card, 20, 20)
        reorder.start(rule.id)
      }} onDragEnd={reorder.end} onKeyDown={event => {
        if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return
        event.preventDefault()
        event.stopPropagation()
        reorder.move(rule.id, event.key === "ArrowUp" ? -1 : 1)
      }}><GripVertical aria-hidden="true" /></Button>
      <Field inert={dragging}>
        <FieldLabel htmlFor={`filter-field-${rule.id}`}>Indicator</FieldLabel>
        <Select value={rule.field} onValueChange={field => { if (Object.hasOwn(FILTER_FIELDS, field)) onChange(makeFilterRule(field as FilterField, rule.id)) }}>
          <SelectTrigger id={`filter-field-${rule.id}`} className="w-full" aria-label={`Indicator for condition ${index + 1}`}><SelectValue /></SelectTrigger>
          <SelectContent position="popper" align="start">
            {FILTER_GROUPS.map(group => <SelectGroup key={group}>
              <SelectLabel>{group}</SelectLabel>
              {(Object.entries(FILTER_FIELDS) as [FilterField, typeof definition][]).filter(([, field]) => field.group === group).map(([key, field]) => <SelectItem key={key} value={key}>{field.label}</SelectItem>)}
            </SelectGroup>)}
          </SelectContent>
        </Select>
      </Field>
      <Field inert={dragging}>
        <FieldLabel htmlFor={`filter-operator-${rule.id}`}>Comparison</FieldLabel>
        <Select value={rule.operator} onValueChange={operator => { if (operatorsFor(rule.field).includes(operator as FilterOperator)) onChange({ ...rule, operator: operator as FilterOperator }) }}>
          <SelectTrigger id={`filter-operator-${rule.id}`} className="w-full" aria-label={`Comparison for condition ${index + 1}`}><SelectValue /></SelectTrigger>
          <SelectContent position="popper"><SelectGroup>
            {operatorsFor(rule.field).map(operator => <SelectItem key={operator} value={operator}>{FILTER_OPERATOR_LABELS[operator]}</SelectItem>)}
          </SelectGroup></SelectContent>
        </Select>
      </Field>
      <Field data-invalid={Boolean(error)} inert={dragging}>
        <FieldLabel htmlFor={requiresFilterValue(rule.operator) ? valueId : undefined}>{rule.operator === "between" ? "Minimum / maximum" : "Value"}</FieldLabel>
        {requiresFilterValue(rule.operator) ? definition.kind === "choice" ?
          <Select value={rule.value} onValueChange={value => { if (definition.choices?.some(choice => choice.value === value)) onChange({ ...rule, value }) }}>
            <SelectTrigger id={valueId} className="w-full" aria-label={`Value for condition ${index + 1}`} aria-invalid={Boolean(error)} aria-describedby={error ? errorId : undefined}><SelectValue /></SelectTrigger>
            <SelectContent position="popper"><SelectGroup>
              {definition.choices?.map(c => <SelectItem key={c.value} value={c.value}>{c.label}</SelectItem>)}
            </SelectGroup></SelectContent>
          </Select> : <div className="flex items-center gap-2">
            <Input id={valueId} name={valueId} type="text" inputMode="decimal" autoComplete="off" spellCheck={false} placeholder={rule.operator === "between" ? "Min…" : "Number…"} value={rule.value} onChange={event => onChange({ ...rule, value: event.target.value })} aria-label={`${rule.operator === "between" ? "Minimum" : "Value"} for condition ${index + 1}`} aria-invalid={Boolean(error)} aria-describedby={error ? errorId : undefined} />
            {rule.operator === "between" && <Input name={`filter-upper-${rule.id}`} type="text" inputMode="decimal" autoComplete="off" spellCheck={false} placeholder="Max…" value={rule.upper} onChange={event => onChange({ ...rule, upper: event.target.value })} aria-label={`Maximum for condition ${index + 1}`} aria-invalid={Boolean(error)} aria-describedby={error ? errorId : undefined} />}
          </div> : <FieldDescription>No value needed.</FieldDescription>}
        {error && <FieldError id={errorId}>{error}</FieldError>}
      </Field>
      <FieldDescription className="pt-7" inert={dragging}>{definition.description}</FieldDescription>
      <Button type="button" variant="ghost" size="icon" className="mt-6" inert={dragging} onClick={onRemove} aria-label={`Remove condition ${index + 1}`}><X aria-hidden="true" /></Button>
    </FieldGroup>
  </FieldSet>
}

export function MarketFilters({ filters, draft: draftOverride, onDraftChange, onApply, combinations, combinationId, onSelectCombination, onSaveCombination, onDeleteCombination, matches, total }: Props) {
  const [open, setOpen] = useState(true)
  const draft = draftOverride ?? filters
  const preview = previewMarketFilters(draft)
  const [showErrors, setShowErrors] = useState(false)
  const [saving, setSaving] = useState<"filters" | "combination" | "selection" | "delete" | null>(null)
  const [saveError, setSaveError] = useState("")
  const [feedback, setFeedback] = useState("")
  const [nameDraft, setNameDraft] = useState<{ combinationId: string; value: string } | null>(null)
  const [nameError, setNameError] = useState("")
  const [draggingId, setDraggingId] = useState<string | null>(null)
  const [dropIndex, setDropIndex] = useState<number | null>(null)
  const selectedCombination = combinations.find(combination => combination.id === combinationId)
  const combinationName = nameDraft && nameDraft.combinationId === combinationId ? nameDraft.value : selectedCombination?.name ?? ""
  const existingCombination = combinations.find(combination => combination.name.toLowerCase() === combinationName.trim().toLowerCase())
  const formRef = useRef<HTMLFormElement>(null)
  const dirty = JSON.stringify(filters) !== JSON.stringify(draft)
  const invalid = draft.rules.some(rule => validateFilterRule(rule) !== null)
  const edit = (next: FilterConfig) => { onDraftChange(next); setSaveError(""); setFeedback("") }
  const reorderRule = (sourceId: string, insertionIndex: number, focus = false) => {
    if (saving) return
    const next = reorderFilterRules(draft, sourceId, insertionIndex)
    if (next === draft) return
    edit(next)
    setFeedback(`Condition moved to position ${next.rules.findIndex(rule => rule.id === sourceId) + 1}.`)
    if (focus) window.requestAnimationFrame(() => document.getElementById(`filter-reorder-${sourceId}`)?.focus())
  }
  const insertionIndexAt = (container: HTMLElement, pointerY: number) => {
    const conditions = [...container.querySelectorAll<HTMLElement>("[data-filter-condition]")]
    const index = conditions.findIndex(condition => {
      const bounds = condition.getBoundingClientRect()
      return pointerY < bounds.top + bounds.height / 2
    })
    const insertionIndex = index < 0 ? conditions.length : index
    const source = draft.rules.findIndex(rule => rule.id === draggingId)
    return insertionIndex === source || insertionIndex === source + 1 ? null : insertionIndex
  }
  const endDrag = () => { setDraggingId(null); setDropIndex(null) }
  const reorder: ReorderControls = {
    draggingId, disabled: Boolean(saving),
    start: id => { setDraggingId(id); setDropIndex(null) }, end: endDrag,
    move: (id, direction) => {
      const index = draft.rules.findIndex(rule => rule.id === id)
      if (index >= 0 && draft.rules[index + direction]) reorderRule(id, direction > 0 ? index + 2 : index - 1, true)
    },
  }
  const validate = (next: FilterConfig) => {
    setShowErrors(true)
    if (next.rules.some(rule => validateFilterRule(rule))) {
      window.requestAnimationFrame(() => formRef.current?.querySelector<HTMLElement>("[aria-label^='Condition '] [aria-invalid=true]")?.focus())
      return false
    }
    return true
  }
  const save = async (next: FilterConfig) => {
    if (!validate(next)) return
    setSaving("filters")
    setSaveError("")
    try {
      await onApply(next)
      onDraftChange(null)
      setShowErrors(false)
      setFeedback(next.rules.length ? "Filters applied and saved." : "Filters cleared.")
    } catch (cause) { setOpen(true); setSaveError(cause instanceof Error ? cause.message : "Cannot save filters. Try again.") }
    finally { setSaving(null) }
  }
  const saveCombination = async () => {
    if (!validate(draft)) return
    const name = combinationName.trim()
    if (!name || name.length > 80) {
      setNameError("Enter a name from 1 to 80 characters.")
      formRef.current?.querySelector<HTMLElement>("#filter-combination-name")?.focus()
      return
    }
    setSaving("combination")
    setSaveError("")
    setNameError("")
    try {
      await onSaveCombination(name, draft)
      setNameDraft(null)
      setShowErrors(false)
      setFeedback("Combination saved. Apply filters to confirm the draft.")
    } catch (cause) { setOpen(true); setSaveError(cause instanceof Error ? cause.message : "Cannot save combination. Try again.") }
    finally { setSaving(null) }
  }
  const loadCombination = async (id: string) => {
    const combination = combinations.find(item => item.id === id)
    if (!combination) return
    setSaving("selection")
    setSaveError("")
    try {
      await onSelectCombination(id)
      setNameDraft(null)
      setNameError("")
      setShowErrors(false)
      edit(parseMarketFilters(combination.filtersJSON))
    } catch (cause) { setOpen(true); setSaveError(cause instanceof Error ? cause.message : "Cannot remember combination. Try again.") }
    finally { setSaving(null) }
  }
  const deleteCombination = async () => {
    if (!selectedCombination) return
    setSaving("delete")
    setSaveError("")
    try {
      await onDeleteCombination(selectedCombination.id)
      setNameDraft(null)
      setNameError("")
      setFeedback("Saved combination deleted.")
    } catch (cause) { setOpen(true); setSaveError(cause instanceof Error ? cause.message : "Cannot delete combination. Try again.") }
    finally { setSaving(null) }
  }
  return <Collapsible open={open} onOpenChange={setOpen} className="border-b">
    <div className="flex items-center gap-3 px-4 py-2">
      <CollapsibleTrigger asChild><Button variant="outline"><Filter data-icon="inline-start" aria-hidden="true" />Filters{preview.rules.length > 0 && <Badge variant="secondary">{preview.rules.length}</Badge>}</Button></CollapsibleTrigger>
      <div className="flex min-w-0 flex-1 items-center gap-2">
        {preview.rules.length ? <>
          <span className="shrink-0 text-xs text-muted-foreground">Match {preview.match === "all" ? "all" : "any"}</span>
          <span className="truncate text-xs" title={preview.rules.map(describeFilterRule).join(preview.match === "all" ? " AND " : " OR ")}>{preview.rules.map(describeFilterRule).join(" · ")}</span>
        </> : <span className="text-xs text-muted-foreground">Combine trend, momentum, breakouts, participation, and price conditions.</span>}
      </div>
      {dirty && <Badge variant="outline">Previewing changes</Badge>}
      {filters.rules.length > 0 && <Button variant="ghost" size="sm" disabled={Boolean(saving)} onClick={() => { edit(emptyMarketFilters()); void save(emptyMarketFilters()) }}><RotateCcw data-icon="inline-start" aria-hidden="true" />Clear filters</Button>}
    </div>
    <CollapsibleContent>
      <form ref={formRef} className="flex flex-col gap-3 px-4 pb-4" onSubmit={event => { event.preventDefault(); void save(draft) }} noValidate>
        <fieldset disabled={Boolean(saving)} className="flex flex-col gap-3">
          <legend className="sr-only">Market filters</legend>
          <div className="flex items-end gap-4">
            <FieldGroup className="grid w-[26rem] shrink-0 grid-cols-[auto_15rem] items-end gap-4">
              <Field>
                <FieldLabel id="filter-match-label">Match conditions</FieldLabel>
                <ToggleGroup type="single" variant="outline" spacing={0} value={draft.match} onValueChange={match => { if (match) edit({ ...draft, match: match as "all" | "any" }) }} aria-labelledby="filter-match-label">
                  <ToggleGroupItem value="all">All (AND)</ToggleGroupItem><ToggleGroupItem value="any">Any (OR)</ToggleGroupItem>
                </ToggleGroup>
              </Field>
              <Field>
                <FieldLabel htmlFor="filter-preset">Start from a preset</FieldLabel>
                <Select value="" onValueChange={id => { if (id) { edit(marketFilterPreset(id)); setShowErrors(false) } }}>
                  <SelectTrigger id="filter-preset" className="w-full"><SelectValue placeholder="Choose preset…" /></SelectTrigger>
                  <SelectContent position="popper"><SelectGroup>{FILTER_PRESETS.map(preset => <SelectItem key={preset.id} value={preset.id}>{preset.label}</SelectItem>)}</SelectGroup></SelectContent>
                </Select>
              </Field>
            </FieldGroup>
            <Button type="button" variant="outline" onClick={() => edit({ ...draft, rules: [...draft.rules, makeFilterRule()] })}><Plus data-icon="inline-start" aria-hidden="true" />Add condition</Button>
            <span className="ml-auto pb-1 text-xs text-muted-foreground" role="status">Preview: {matches} / {total} markets{invalid ? " · Incomplete conditions skipped." : ""}</span>
          </div>
          <FieldGroup className="grid grid-cols-[20rem_20rem_auto_auto_minmax(0,1fr)] items-end gap-3">
            <Field>
              <FieldLabel htmlFor="filter-saved-combinations">Saved combinations</FieldLabel>
              <div className="flex items-center gap-2">
                <Select value={selectedCombination?.id ?? ""} disabled={!combinations.length} onValueChange={id => { void loadCombination(id) }}>
                  <SelectTrigger id="filter-saved-combinations" className="w-full min-w-0"><SelectValue placeholder={combinations.length ? "Choose saved combination…" : "No saved combinations"} /></SelectTrigger>
                  <SelectContent position="popper"><SelectGroup>{combinations.map(combination => <SelectItem key={combination.id} value={combination.id}>{combination.name}</SelectItem>)}</SelectGroup></SelectContent>
                </Select>
                <Button type="button" variant="ghost" size="icon" disabled={!selectedCombination} onClick={() => { if (selectedCombination) void loadCombination(selectedCombination.id) }} aria-label="Reload selected combination" title="Reload selected combination">{saving === "selection" ? <Spinner aria-hidden="true" /> : <RotateCcw aria-hidden="true" />}</Button>
              </div>
            </Field>
            <Field data-invalid={Boolean(nameError)}>
              <FieldLabel htmlFor="filter-combination-name">Combination name</FieldLabel>
              <Input id="filter-combination-name" name="combinationName" value={combinationName} onChange={event => { setNameDraft({ combinationId, value: event.target.value }); setNameError("") }} maxLength={80} autoComplete="off" placeholder="Name this combination…" aria-invalid={Boolean(nameError)} aria-describedby={nameError ? "filter-combination-name-error" : undefined} />
              {nameError && <FieldError id="filter-combination-name-error">{nameError}</FieldError>}
            </Field>
            <Button type="button" variant="outline" onClick={() => { void saveCombination() }}>{saving === "combination" ? <Spinner data-icon="inline-start" aria-hidden="true" /> : <Save data-icon="inline-start" aria-hidden="true" />}{existingCombination ? "Update combination" : "Save combination"}</Button>
            <Button type="button" variant="ghost" disabled={!selectedCombination} onClick={() => { void deleteCombination() }} aria-label={selectedCombination ? `Delete saved combination ${selectedCombination.name}` : "Delete saved combination"}>{saving === "delete" ? <Spinner data-icon="inline-start" aria-hidden="true" /> : <Trash2 data-icon="inline-start" aria-hidden="true" />}Delete combination</Button>
            <FieldDescription className="pb-1">Saved combinations load into the draft. Apply filters to confirm.</FieldDescription>
          </FieldGroup>
          <p className="text-xs text-muted-foreground">Draft changes preview the list immediately. Complete all conditions before applying. Numeric ranges include both endpoints. Combine sign with an absolute threshold for ROC/MAROC. Missing data matches only “Unavailable”; all conditions use live 1h readings.</p>
          <FieldGroup className={cn("gap-2", draggingId && "select-none")} onDragOver={event => {
            if (saving || !draggingId) return
            event.preventDefault()
            event.dataTransfer.dropEffect = "move"
            setDropIndex(insertionIndexAt(event.currentTarget, event.clientY))
          }} onDragLeave={event => {
            const bounds = event.currentTarget.getBoundingClientRect()
            if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) setDropIndex(null)
          }} onDrop={event => {
            if (saving || !draggingId) return
            event.preventDefault()
            const insertionIndex = insertionIndexAt(event.currentTarget, event.clientY)
            if (insertionIndex !== null) reorderRule(draggingId, insertionIndex)
            endDrag()
          }}>
            {draft.rules.map((rule, index) => <div key={rule.id} className="relative">
              {dropIndex === index && <FilterInsertionLine />}
              <FilterCondition rule={rule} index={index} showError={showErrors} reorder={reorder} onChange={next => edit({ ...draft, rules: draft.rules.map(r => r.id === rule.id ? next : r) })} onRemove={() => edit({ ...draft, rules: draft.rules.filter(r => r.id !== rule.id) })} />
              {index === draft.rules.length - 1 && dropIndex === draft.rules.length && <FilterInsertionLine atEnd />}
            </div>)}
          </FieldGroup>
          {!draft.rules.length && <Empty>
            <EmptyHeader><EmptyTitle>No indicator conditions</EmptyTitle><EmptyDescription>Add a condition or choose a preset. Settings still control turnover, spread, and listing age.</EmptyDescription></EmptyHeader>
          </Empty>}
          <div className="flex items-center gap-2">
            <Button type="submit" disabled={Boolean(saving)}>{saving === "filters" ? <Spinner data-icon="inline-start" aria-hidden="true" /> : <Check data-icon="inline-start" aria-hidden="true" />}{saving === "filters" ? "Saving…" : "Apply filters"}</Button>
            <Button type="button" variant="outline" disabled={!dirty || Boolean(saving)} onClick={() => { onDraftChange(null); setSaveError(""); setFeedback(""); setShowErrors(false) }}>Discard changes</Button>
            <Button type="button" variant="ghost" disabled={!draft.rules.length || Boolean(saving)} onClick={() => edit(emptyMarketFilters())}>Reset draft</Button>
            <span className="ml-auto text-xs text-muted-foreground">Applied filters persist across app restarts.</span>
          </div>
        </fieldset>
        {saveError && <FieldError>{saveError}</FieldError>}
        <span id="filter-reorder-help" className="sr-only">Drag a condition by its handle to reorder it, or focus the handle and use ArrowUp or ArrowDown.</span>
        <span className="sr-only" role="status">{feedback}</span>
      </form>
    </CollapsibleContent>
  </Collapsible>
}
