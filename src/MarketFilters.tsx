import { useMemo, useRef, useState } from "react"
import { Check, Filter, Plus, RotateCcw, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/components/ui/empty"
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel, FieldLegend, FieldSet } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Select, SelectContent, SelectGroup, SelectItem, SelectLabel, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Spinner } from "@/components/ui/spinner"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import {
  FILTER_FIELDS, FILTER_GROUPS, FILTER_OPERATOR_LABELS, FILTER_PRESETS, describeFilterRule, emptyMarketFilters,
  makeFilterRule, marketFilterPreset, operatorsFor, requiresFilterValue, validateFilterRule,
  type FilterField, type FilterOperator, type FilterRule, type MarketFilters as FilterConfig,
} from "@/market-filters"

type Props = {
  filters: FilterConfig
  onApply: (filters: FilterConfig) => Promise<void>
  countMatches: (filters: FilterConfig) => number
  total: number
}

function FilterCondition({ rule, index, onChange, onRemove, showError }: {
  rule: FilterRule; index: number; onChange: (rule: FilterRule) => void; onRemove: () => void; showError: boolean
}) {
  const definition = FILTER_FIELDS[rule.field]
  const error = showError ? validateFilterRule(rule) : null
  const valueId = `filter-value-${rule.id}`
  const errorId = `filter-error-${rule.id}`
  return <FieldSet className="rounded-lg border p-3" aria-label={`Condition ${index + 1}`}>
    <FieldLegend className="sr-only">Condition {index + 1}</FieldLegend>
    <FieldGroup className="grid grid-cols-[18rem_13rem_20rem_minmax(0,1fr)_auto] items-start gap-3">
      <Field>
        <FieldLabel htmlFor={`filter-field-${rule.id}`}>Indicator</FieldLabel>
        <Select value={rule.field} onValueChange={field => onChange(makeFilterRule(field as FilterField, rule.id))}>
          <SelectTrigger id={`filter-field-${rule.id}`} className="w-full" aria-label={`Indicator for condition ${index + 1}`}><SelectValue /></SelectTrigger>
          <SelectContent position="popper" align="start">
            {FILTER_GROUPS.map(group => <SelectGroup key={group}>
              <SelectLabel>{group}</SelectLabel>
              {(Object.entries(FILTER_FIELDS) as [FilterField, typeof definition][]).filter(([, field]) => field.group === group).map(([key, field]) => <SelectItem key={key} value={key}>{field.label}</SelectItem>)}
            </SelectGroup>)}
          </SelectContent>
        </Select>
      </Field>
      <Field>
        <FieldLabel htmlFor={`filter-operator-${rule.id}`}>Comparison</FieldLabel>
        <Select value={rule.operator} onValueChange={operator => onChange({ ...rule, operator: operator as FilterOperator })}>
          <SelectTrigger id={`filter-operator-${rule.id}`} className="w-full" aria-label={`Comparison for condition ${index + 1}`}><SelectValue /></SelectTrigger>
          <SelectContent position="popper"><SelectGroup>
            {operatorsFor(rule.field).map(operator => <SelectItem key={operator} value={operator}>{FILTER_OPERATOR_LABELS[operator]}</SelectItem>)}
          </SelectGroup></SelectContent>
        </Select>
      </Field>
      <Field data-invalid={Boolean(error)}>
        <FieldLabel htmlFor={requiresFilterValue(rule.operator) ? valueId : undefined}>{rule.operator === "between" ? "Minimum / maximum" : "Value"}</FieldLabel>
        {requiresFilterValue(rule.operator) ? definition.kind === "choice" ?
          <Select value={rule.value} onValueChange={value => onChange({ ...rule, value })}>
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
      <FieldDescription className="pt-7">{definition.description}</FieldDescription>
      <Button type="button" variant="ghost" size="icon" className="mt-6" onClick={onRemove} aria-label={`Remove condition ${index + 1}`}><X aria-hidden="true" /></Button>
    </FieldGroup>
  </FieldSet>
}

export function MarketFilters({ filters, onApply, countMatches, total }: Props) {
  const [open, setOpen] = useState(false)
  const [draftOverride, setDraft] = useState<FilterConfig | null>(null)
  const draft = draftOverride ?? filters
  const [showErrors, setShowErrors] = useState(false)
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState("")
  const [feedback, setFeedback] = useState("")
  const formRef = useRef<HTMLFormElement>(null)
  const dirty = JSON.stringify(filters) !== JSON.stringify(draft)
  const invalid = draft.rules.some(rule => validateFilterRule(rule) !== null)
  const matches = useMemo(() => invalid ? null : countMatches(draft), [countMatches, draft, invalid])
  const edit = (next: FilterConfig) => { setDraft(next); setSaveError(""); setFeedback("") }
  const save = async (next: FilterConfig) => {
    setShowErrors(true)
    if (next.rules.some(rule => validateFilterRule(rule))) {
      window.requestAnimationFrame(() => formRef.current?.querySelector<HTMLElement>("[aria-invalid=true]")?.focus())
      return
    }
    setSaving(true)
    setSaveError("")
    try {
      await onApply(next)
      setDraft(null)
      setShowErrors(false)
      setFeedback(next.rules.length ? "Filters applied and saved." : "Filters cleared.")
    } catch (cause) { setOpen(true); setSaveError(cause instanceof Error ? cause.message : "Cannot save filters. Try again.") }
    finally { setSaving(false) }
  }
  return <Collapsible open={open} onOpenChange={setOpen} className="border-b">
    <div className="flex items-center gap-3 px-4 py-2">
      <CollapsibleTrigger asChild><Button variant="outline" size="sm"><Filter data-icon="inline-start" aria-hidden="true" />Filters{filters.rules.length > 0 && <Badge variant="secondary">{filters.rules.length}</Badge>}</Button></CollapsibleTrigger>
      <div className="flex min-w-0 flex-1 items-center gap-2">
        {filters.rules.length ? <>
          <span className="shrink-0 text-xs text-muted-foreground">Match {filters.match === "all" ? "all" : "any"}</span>
          <span className="truncate text-xs" title={filters.rules.map(describeFilterRule).join(filters.match === "all" ? " AND " : " OR ")}>{filters.rules.map(describeFilterRule).join(" · ")}</span>
        </> : <span className="text-xs text-muted-foreground">Combine trend, momentum, breakouts, participation, and price conditions.</span>}
      </div>
      {dirty && <Badge variant="outline">Unapplied changes</Badge>}
      {filters.rules.length > 0 && <Button variant="ghost" size="sm" disabled={saving} onClick={() => { edit(emptyMarketFilters()); void save(emptyMarketFilters()) }}><RotateCcw data-icon="inline-start" aria-hidden="true" />Clear filters</Button>}
    </div>
    <CollapsibleContent>
      <form ref={formRef} className="flex flex-col gap-3 px-4 pb-4" onSubmit={event => { event.preventDefault(); void save(draft) }} noValidate>
        <fieldset disabled={saving} className="flex flex-col gap-3">
          <legend className="sr-only">Market filters</legend>
          <div className="flex items-end gap-4">
            <FieldGroup className="grid w-[26rem] shrink-0 grid-cols-[auto_15rem] items-end gap-4">
              <Field>
                <FieldLabel id="filter-match-label">Match conditions</FieldLabel>
                <ToggleGroup type="single" variant="outline" size="sm" spacing={0} value={draft.match} onValueChange={match => { if (match) edit({ ...draft, match: match as "all" | "any" }) }} aria-labelledby="filter-match-label">
                  <ToggleGroupItem value="all">All (AND)</ToggleGroupItem><ToggleGroupItem value="any">Any (OR)</ToggleGroupItem>
                </ToggleGroup>
              </Field>
              <Field>
                <FieldLabel htmlFor="filter-preset">Start from a preset</FieldLabel>
                <Select value="" onValueChange={id => { edit(marketFilterPreset(id)); setShowErrors(false) }}>
                  <SelectTrigger id="filter-preset" className="w-full"><SelectValue placeholder="Choose preset…" /></SelectTrigger>
                  <SelectContent position="popper"><SelectGroup>{FILTER_PRESETS.map(preset => <SelectItem key={preset.id} value={preset.id}>{preset.label}</SelectItem>)}</SelectGroup></SelectContent>
                </Select>
              </Field>
            </FieldGroup>
            <Button type="button" variant="outline" onClick={() => edit({ ...draft, rules: [...draft.rules, makeFilterRule()] })}><Plus data-icon="inline-start" aria-hidden="true" />Add condition</Button>
            <span className="ml-auto pb-1 text-xs text-muted-foreground" role="status">{matches === null ? "Complete the conditions to preview matches." : `Preview: ${matches} / ${total} markets`}</span>
          </div>
          <p className="text-xs text-muted-foreground">Numeric ranges include both endpoints. Combine sign with an absolute threshold for ROC/MAROC. Missing data matches only “Unavailable”; all conditions use live 1h readings.</p>
          <FieldGroup className="gap-2">
            {draft.rules.map((rule, index) => <FilterCondition key={rule.id} rule={rule} index={index} showError={showErrors} onChange={next => edit({ ...draft, rules: draft.rules.map(r => r.id === rule.id ? next : r) })} onRemove={() => edit({ ...draft, rules: draft.rules.filter(r => r.id !== rule.id) })} />)}
          </FieldGroup>
          {!draft.rules.length && <Empty>
            <EmptyHeader><EmptyTitle>No indicator conditions</EmptyTitle><EmptyDescription>Add a condition or choose a preset. Settings still control turnover, spread, and listing age.</EmptyDescription></EmptyHeader>
          </Empty>}
          <div className="flex items-center gap-2">
            <Button type="submit" disabled={saving}>{saving ? <Spinner data-icon="inline-start" aria-hidden="true" /> : <Check data-icon="inline-start" aria-hidden="true" />}{saving ? "Saving…" : "Apply filters"}</Button>
            <Button type="button" variant="outline" disabled={!dirty || saving} onClick={() => { setDraft(null); setSaveError(""); setFeedback(""); setShowErrors(false) }}>Discard changes</Button>
            <Button type="button" variant="ghost" disabled={!draft.rules.length || saving} onClick={() => edit(emptyMarketFilters())}>Reset draft</Button>
            <span className="ml-auto text-xs text-muted-foreground">Applied filters persist across app restarts.</span>
          </div>
        </fieldset>
        {saveError && <FieldError>{saveError}</FieldError>}
        <span className="sr-only" role="status">{feedback}</span>
      </form>
    </CollapsibleContent>
  </Collapsible>
}
