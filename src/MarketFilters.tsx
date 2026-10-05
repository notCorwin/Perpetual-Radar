import { useRef, useState, type Dispatch, type SetStateAction } from "react"
import { Check, ChevronDown, Code, Copy, Filter, GripVertical, Plus, RotateCcw, Save, Search, Trash2, X } from "lucide-react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command"
import { Empty, EmptyDescription, EmptyHeader, EmptyTitle } from "@/components/ui/empty"
import { Field, FieldDescription, FieldError, FieldGroup, FieldLabel, FieldLegend, FieldSet } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { Spinner } from "@/components/ui/spinner"
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs"
import { Textarea } from "@/components/ui/textarea"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import { cn } from "@/lib/utils"
import {
  canReceiveChildren, categoryComparisons, comparisons, duplicateRule, emptyFilterConfig, formulaExamples, indicatorTemplates, makeRule, moveRule, newRuleID,
  parseFilterConfig, removeRule, ruleCount, ruleKinds, unaryComparison, updateRule,
  type FilterCombination, type FilterConfigV2, type FilterEditorState, type FilterMetric, type NamedFormula, type RuleKind, type RuleNode,
} from "@/rule-engine"

type Props = {
  filters: FilterConfigV2; draft: FilterConfigV2 | null; editor: FilterEditorState
  onDraftChange: (draft: FilterConfigV2 | null) => void; onEditorChange: Dispatch<SetStateAction<FilterEditorState>>
  onApply: (filters: FilterConfigV2) => Promise<void>; combinations: FilterCombination[]; combinationId: string
  onSelectCombination: (id: string) => Promise<void>; onSaveCombination: (name: string, filters: FilterConfigV2) => Promise<FilterCombination>; onDeleteCombination: (id: string) => Promise<void>
  metrics: FilterMetric[]; functions: string[]; units: Record<string, string>; formula: string; diagnostics: string[]; valid: boolean; compiling: boolean; requiredHours: number
  matches: number; total: number; unknown: number; previewPending: boolean; history: { pending: number; completed: number; error: string } | null
}

function Picker({ value, choices, onChange, label }: { value: string; choices: string[][]; onChange: (value: string) => void; label: string }) {
  return <Select value={value} onValueChange={onChange}><SelectTrigger className="w-full" aria-label={label}><SelectValue /></SelectTrigger><SelectContent position="popper"><SelectGroup>{choices.map(([key, title]) => <SelectItem key={key} value={key}>{title}</SelectItem>)}</SelectGroup></SelectContent></Select>
}

type ExpressionInputProps = { label: string; value: string; onChange: (value: string) => void; onSelectExpression?: (value: string) => void; metrics: FilterMetric[]; definitions: NamedFormula[]; choices?: { value: string; label: string }[]; unit?: string; units?: Record<string, string> }
function ExpressionInput({ label, value, onChange, onSelectExpression, metrics, definitions, choices = [], unit, units = {} }: ExpressionInputProps) {
  const [open, setOpen] = useState(false)
  const input = useRef<HTMLInputElement>(null)
  const template = indicatorTemplates.find(item => item.expression.split("(")[0].toLowerCase() === value.split("(")[0].trim().toLowerCase())
  const parameters = template && value.match(/^[A-Za-z]+\(([^()]*)\)$/)?.[1].split(",").map(item => item.trim())
  const reading = metrics.find(metric => metric.key.toLowerCase() === value.trim().toLowerCase())
  const insert = (expression: string) => { (onSelectExpression ?? onChange)(expression); setOpen(false); window.requestAnimationFrame(() => input.current?.focus()) }
  return <Field>
    <FieldLabel>{label}</FieldLabel>
    <div className="flex items-center gap-1">
      <Input ref={input} value={value} onChange={event => onChange(event.target.value)} onKeyDown={event => { if (event.key === " " && event.ctrlKey) { event.preventDefault(); setOpen(true) } }} aria-label={label} autoComplete="off" spellCheck={false} />
      <Popover open={open} onOpenChange={setOpen}>
        <PopoverTrigger asChild><Button type="button" variant="outline" size="icon" aria-label={`Choose ${label}`} title="Find a metric or function (Ctrl+Space)"><Search aria-hidden="true" /></Button></PopoverTrigger>
        <PopoverContent className="w-[28rem] p-0" align="start"><Command>
          <CommandInput placeholder="Find a metric, indicator, or named formula…" />
          <CommandList><CommandEmpty>No matching expressions.</CommandEmpty>
            {choices.length > 0 && <CommandGroup heading="Values">{choices.map(choice => <CommandItem key={choice.value} value={`value ${choice.label}`} onSelect={() => insert(JSON.stringify(choice.value))}>{choice.label}</CommandItem>)}</CommandGroup>}
            <CommandGroup heading="Parameterized indicators">{indicatorTemplates.map(item => <CommandItem key={item.expression} value={`${item.label} ${item.expression}`} onSelect={() => insert(item.expression)}>{item.label}<span className="ml-auto text-muted-foreground">{item.unit}</span></CommandItem>)}</CommandGroup>
            {definitions.length > 0 && <CommandGroup heading="Named formulas / earlier captures">{definitions.map(item => <CommandItem key={item.id} value={item.name} onSelect={() => insert(item.name)}>{item.name}</CommandItem>)}</CommandGroup>}
            {[...new Set(metrics.map(metric => metric.group))].map(group => <CommandGroup key={group} heading={group}>{metrics.filter(metric => metric.group === group).map(metric => <CommandItem key={metric.key} value={`${metric.label} ${metric.key}`} onSelect={() => insert(metric.key)}>{metric.label}<span className="ml-auto text-muted-foreground">{metric.unit}</span></CommandItem>)}</CommandGroup>)}
          </CommandList>
        </Command></PopoverContent>
      </Popover>
    </div>
    <FieldDescription>{reading?.unit ?? template?.unit ?? ((Number.isFinite(Number(value)) && value.trim() || units[value] === "constant") ? unit ? `${unit} (constant)` : "Numeric constant" : units[value] ?? unit ?? "Enter an expression to resolve its unit")}</FieldDescription>
    {parameters && parameters.length === template?.params.length && <FieldGroup className="grid grid-cols-2 gap-2">{parameters.map((parameter, index) => <Field key={index}>
      <FieldLabel>{template.params[index]}</FieldLabel><Input type="number" min={index === 1 && template.label.startsWith("Log BB") ? "0" : "1"} step={index === 1 && template.label.startsWith("Log BB") ? "any" : "1"} value={parameter} aria-label={`${label} ${template.params[index]}`} onChange={event => { const next = [...parameters]; next[index] = event.target.value; onChange(`${value.split("(")[0]}(${next.join(", ")})`) }} />
    </Field>)}</FieldGroup>}
  </Field>
}

function CategoryValueInput(props: ExpressionInputProps) {
  const [custom, setCustom] = useState(false)
  const choices = props.choices ?? []
  const selected = choices.find(choice => JSON.stringify(choice.value) === props.value.trim())
  const expression = custom || !selected
  return <FieldGroup className="gap-2">
    <Field><FieldLabel>Right value</FieldLabel><Picker label="Right value" value={expression ? "expression" : selected.value} choices={[...choices.map(choice => [choice.value, choice.label]), ["expression", "Custom expression…"]]} onChange={value => {
      setCustom(value === "expression")
      if (value !== "expression") props.onChange(JSON.stringify(value))
    }} />{!expression && <FieldDescription>Category</FieldDescription>}</Field>
    {expression && <ExpressionInput {...props} />}
  </FieldGroup>
}

function newBranch(kind: RuleKind): RuleNode {
  const node = makeRule(kind)
  if (["all", "any", "not", "every", "recent", "count"].includes(kind)) node.children = [makeRule()]
  if (kind === "sequence") {
    node.hours = 6
    const first = { ...makeRule(), name: "break", left: "High", comparison: "gt", right: "PriorHigh(48)", captures: [{ id: newRuleID(), name: "level", expression: "PriorHigh(48)" }] }
    const retest = { ...makeRule(), name: "retest", left: "Low", comparison: "lte", right: "break.level" }
    const reclaim = { ...makeRule("crossup"), name: "reclaim", left: "Close", right: "break.level" }
    node.children = [first, retest, reclaim]
  }
  return node
}

function captureScope(root: RuleNode, target: string, scope: NamedFormula[] = []): NamedFormula[] | null {
  if (root.id === target) return scope
  const next = [...scope]
  for (const child of root.children) {
    const found = captureScope(child, target, next)
    if (found) return found
    if (root.kind === "sequence") next.push(...child.captures.map(item => ({ ...item, name: `${child.name}.${item.name}` })))
  }
  return null
}

type TreeProps = { config: FilterConfigV2; edit: (config: FilterConfigV2) => void; metrics: FilterMetric[]; units: Record<string, string>; editor: FilterEditorState; setEditor: Dispatch<SetStateAction<FilterEditorState>>; disabled: boolean; dragging: string | null; setDragging: (id: string | null) => void; drop: { parent: string; index: number } | null; setDrop: (drop: { parent: string; index: number } | null) => void }

function RuleCard({ node, parent, index = 0, tree }: { node: RuleNode; parent?: RuleNode; index?: number; tree: TreeProps }) {
  const { config, edit, metrics, editor, setEditor } = tree
  const change = (next: Partial<RuleNode>) => edit({ ...config, root: updateRule(config.root, node.id, rule => ({ ...rule, ...next })) })
  const stage = parent?.kind === "sequence"
  const folded = editor.collapsed[node.id] ?? false
  const definitions = [...config.definitions, ...(captureScope(config.root, node.id) ?? [])]
  const propsUnit = (expression: string) => tree.units[expression] ?? metrics.find(item => item.key === expression)?.unit
  const expressionProps = { metrics, definitions, units: tree.units }
  const family = !parent ? ["all", "any"] : ["all", "any", "sequence"].includes(node.kind) ? ["all", "any", "sequence"] : ["not", "every", "recent", "count"].includes(node.kind) ? ["not", "every", "recent", "count"] : ["condition", "crossup", "crossdown"]
  const metric = metrics.find(item => item.key.toLowerCase() === node.left.trim().toLowerCase())
  const rightChoices = metric?.choices ?? []
  const categorical = metric ? !metric.numeric : ["category", "text"].includes(propsUnit(node.left) ?? "")
  const selectLeft = (left: string) => {
    const selected = metrics.find(item => item.key.toLowerCase() === left.toLowerCase())
    const next: Partial<RuleNode> = { left }
    if (node.kind === "condition" && selected) {
      if (!selected.numeric && !categoryComparisons.some(([key]) => key === node.comparison)) next.comparison = "eq"
      if (!unaryComparison(next.comparison ?? node.comparison)) {
        const unit = propsUnit(node.right)
        if (selected.choices.length && (!unit || !["category", "text"].includes(unit) || /^"/.test(node.right.trim()) && !selected.choices.some(choice => JSON.stringify(choice.value) === node.right.trim()))) next.right = JSON.stringify(selected.choices[0].value)
        else if (selected.numeric && /^"/.test(node.right.trim())) next.right = "0"
      }
    }
    change(next)
  }
  const move = (direction: -1 | 1) => {
    if (!parent || !parent.children[index + direction]) return
    const root = moveRule(config.root, node.id, parent.id, direction > 0 ? index + 2 : index - 1)
    edit({ ...config, root }); window.requestAnimationFrame(() => document.getElementById(`move-${node.id}`)?.focus())
  }
  const add = (kind: RuleKind) => {
    const child = newBranch(kind)
    if (node.kind === "sequence") { const names = new Set(node.children.map(item => item.name)); let i = 1; while (names.has(`stage${i}`)) i += 1; child.name = `stage${i}` }
    change({ children: [...node.children, child] })
  }
  return <div className="relative" onDragOver={event => {
    if (!tree.dragging || !parent) return
    event.preventDefault(); event.stopPropagation()
    const bounds = event.currentTarget.getBoundingClientRect(), gap = index + (event.clientY > bounds.top + bounds.height / 2 ? 1 : 0)
    if (moveRule(config.root, tree.dragging, parent.id, gap) !== config.root) tree.setDrop({ parent: parent.id, index: gap })
  }} onDrop={event => {
    if (!tree.dragging || !tree.drop) return
    event.preventDefault(); event.stopPropagation()
    edit({ ...config, root: moveRule(config.root, tree.dragging, tree.drop.parent, tree.drop.index) }); tree.setDragging(null); tree.setDrop(null)
  }}>
    {parent && tree.drop?.parent === parent.id && tree.drop.index === index && <div data-filter-insertion-line aria-hidden="true" className="pointer-events-none absolute inset-x-0 -top-1 h-0.5 bg-primary" />}
    <FieldSet className={cn("rounded-lg border p-3", tree.dragging === node.id && "opacity-50")} aria-label={node.name || `Rule ${index + 1}`}>
      <FieldLegend className="sr-only">{node.name || node.kind}</FieldLegend>
      <div className="flex items-center gap-2">
        {parent && <Button id={`move-${node.id}`} type="button" variant="ghost" size="icon" draggable={!tree.disabled} aria-label={`Move ${node.name || "rule"}`} title="Drag between groups, or use ArrowUp / ArrowDown" onDragStart={event => { event.stopPropagation(); event.dataTransfer.setData("text/plain", node.id); event.dataTransfer.effectAllowed = "move"; tree.setDragging(node.id) }} onDragEnd={() => { tree.setDragging(null); tree.setDrop(null) }} onKeyDown={event => { if (["ArrowUp", "ArrowDown"].includes(event.key)) { event.preventDefault(); move(event.key === "ArrowUp" ? -1 : 1) } }}><GripVertical aria-hidden="true" /></Button>}
        <div className="w-48"><Picker label="Rule type" value={node.kind} choices={ruleKinds.filter(item => family.includes(item.value)).map(item => [item.value, item.label])} onChange={kind => {
          const next = { kind: kind as RuleKind, children: node.children }
          if (kind === "sequence") next.children = node.children.map((child, i) => ({ ...child, name: /^[A-Za-z_][A-Za-z0-9_]*$/.test(child.name) ? child.name : `stage${i + 1}` }))
          change(next)
        }} /></div>
        <Input value={node.name} placeholder={stage ? "Stage identifier" : "Optional rule name"} onChange={event => change({ name: event.target.value })} aria-label={stage ? "Stage name" : "Rule name"} className="max-w-72" />
        <Badge variant="outline">{node.mode === "closed" ? "Closed" : "Live"}</Badge>
        <div className="ml-auto flex items-center gap-1">
          {parent && <Picker label="Wrap rule" value="wrap" choices={[["wrap", "Wrap in…"], ["not", "NOT"], ["every", "Every hour"], ["recent", "Recently"], ["all", "AND group"], ["any", "OR group"]]} onChange={kind => { if (kind !== "wrap") edit({ ...config, root: updateRule(config.root, node.id, original => ({ ...makeRule(kind as RuleKind), name: stage ? original.name : "", gapHours: original.gapHours, captures: stage ? original.captures : [], children: [stage ? { ...original, name: "", captures: [] } : original] })) }) }} />}
          {parent && ["all", "any", "sequence"].includes(parent.kind) && <Button type="button" variant="ghost" size="icon" aria-label="Duplicate rule" onClick={() => edit({ ...config, root: duplicateRule(config.root, node.id) })}><Copy aria-hidden="true" /></Button>}
          <Button type="button" variant="ghost" size="icon" aria-label={folded ? "Expand rule" : "Collapse rule"} aria-expanded={!folded} onClick={() => setEditor(current => ({ ...current, collapsed: { ...current.collapsed, [node.id]: !folded } }))}><ChevronDown aria-hidden="true" className={cn(folded && "-rotate-90")} /></Button>
          {parent && <Button type="button" variant="ghost" size="icon" aria-label="Remove rule" onClick={() => edit({ ...config, root: removeRule(config.root, node.id) })}><X aria-hidden="true" /></Button>}
        </div>
      </div>
      {!folded && <FieldGroup className="mt-3 gap-3">
        {<FieldGroup className={cn("grid gap-3", stage ? "grid-cols-[16rem_12rem_1fr]" : "grid-cols-[16rem_1fr]")}>
          <Field><FieldLabel>Evaluation hour</FieldLabel><ToggleGroup type="single" variant="outline" size="sm" spacing={0} value={node.mode} onValueChange={mode => { if (mode) change({ mode: mode as "live" | "closed" }) }} aria-label="Evaluation hour"><ToggleGroupItem value="live">Live</ToggleGroupItem><ToggleGroupItem value="closed">Closed</ToggleGroupItem></ToggleGroup></Field>
          {stage && <Field><FieldLabel>Maximum gap (h)</FieldLabel><Input type="number" min="1" step="1" value={node.gapHours} aria-label="Maximum stage gap hours" onChange={event => change({ gapHours: Number(event.target.value) })} /></Field>}
          <FieldDescription>Each closed anchor shifts this rule back one hour. Historical offsets remain relative to that anchor.</FieldDescription>
        </FieldGroup>}
        {["condition", "crossup", "crossdown"].includes(node.kind) && <FieldGroup className="grid grid-cols-[minmax(0,1fr)_13rem_minmax(0,1fr)] items-start gap-3">
          <ExpressionInput label="Left expression" value={node.left} onChange={left => change({ left })} onSelectExpression={selectLeft} {...expressionProps} />
          <Field><FieldLabel>Comparison</FieldLabel>{node.kind === "condition" ? <Picker label="Comparison" value={node.comparison} choices={categorical ? categoryComparisons : comparisons} onChange={comparison => change({ comparison })} /> : <FieldDescription>{node.kind === "crossup" ? "Previous ≤, current >" : "Previous ≥, current <"}</FieldDescription>}</Field>
          {(node.kind !== "condition" || !unaryComparison(node.comparison)) && <FieldGroup>{node.kind === "condition" && rightChoices.length > 0 ? <CategoryValueInput label="Right expression" value={node.right} onChange={right => change({ right })} {...expressionProps} choices={rightChoices} unit={propsUnit(node.left)} /> : <ExpressionInput label={node.comparison === "between" ? "Minimum expression" : "Right expression"} value={node.right} onChange={right => change({ right })} {...expressionProps} unit={propsUnit(node.left)} />}{node.comparison === "between" && <ExpressionInput label="Maximum expression" value={node.upper} onChange={upper => change({ upper })} {...expressionProps} unit={propsUnit(node.left)} />}</FieldGroup>}
        </FieldGroup>}
        {["every", "recent", "count", "sequence"].includes(node.kind) && <FieldGroup className="grid grid-cols-[12rem_13rem_12rem_minmax(0,1fr)] gap-3">
          <Field><FieldLabel>{node.kind === "sequence" ? "Maximum span (h)" : "Window hours"}</FieldLabel><Input type="number" min="1" step="1" value={node.hours} aria-label="Window hours" onChange={event => change({ hours: Number(event.target.value) })} /></Field>
          {node.kind === "count" && <><Field><FieldLabel>Count comparison</FieldLabel><Picker label="Count comparison" value={node.comparison} choices={comparisons.filter(([key]) => ["eq", "neq", "gt", "gte", "lt", "lte", "between"].includes(key))} onChange={comparison => change({ comparison })} /></Field><Field><FieldLabel>Count threshold</FieldLabel><Input type="number" min="0" step="1" value={node.minimum} aria-label="Count threshold" onChange={event => change({ minimum: Number(event.target.value) })} /></Field>{node.comparison === "between" && <Field><FieldLabel>Maximum count</FieldLabel><Input type="number" min="0" step="1" value={node.upper} aria-label="Maximum count" onChange={event => change({ upper: event.target.value })} /></Field>}</>}
          {node.kind !== "count" && <FieldDescription>{node.kind === "sequence" ? "Stages run in strict hourly order. The final stage must match the anchor hour. Wrap this sequence in Recently to search earlier completions." : "Includes the anchor and preceding hourly slots. Missing slots are never skipped."}</FieldDescription>}
        </FieldGroup>}
        {stage && <FieldSet><FieldLegend>Capture values at this stage</FieldLegend><FieldGroup className="gap-2">{node.captures.map(item => <FieldGroup key={item.id} className="grid grid-cols-[12rem_minmax(0,1fr)_auto] items-start gap-2"><Field><FieldLabel>Capture name</FieldLabel><Input value={item.name} aria-label="Capture name" onChange={event => change({ captures: node.captures.map(current => current.id === item.id ? { ...current, name: event.target.value } : current) })} /></Field><ExpressionInput label="Captured expression" value={item.expression} onChange={expression => change({ captures: node.captures.map(current => current.id === item.id ? { ...current, expression } : current) })} {...expressionProps} /><Button type="button" variant="ghost" size="icon" className="mt-6" aria-label="Remove capture" onClick={() => change({ captures: node.captures.filter(current => current.id !== item.id) })}><X aria-hidden="true" /></Button></FieldGroup>)}</FieldGroup><Button type="button" variant="outline" size="sm" className="mt-2" onClick={() => change({ captures: [...node.captures, { id: newRuleID(), name: `value${node.captures.length + 1}`, expression: "Price" }] })}><Plus data-icon="inline-start" aria-hidden="true" />Add capture</Button></FieldSet>}
        {node.children.length > 0 && <FieldGroup className="gap-2">{node.children.map((child, childIndex) => <RuleCard key={child.id} node={child} parent={node} index={childIndex} tree={tree} />)}</FieldGroup>}
        {canReceiveChildren(node) && <div className="flex items-center gap-2" onDragOver={event => { if (tree.dragging && moveRule(config.root, tree.dragging, node.id, node.children.length) !== config.root) { event.preventDefault(); event.stopPropagation(); tree.setDrop({ parent: node.id, index: node.children.length }) } }} onDrop={event => { if (tree.dragging) { event.preventDefault(); event.stopPropagation(); edit({ ...config, root: moveRule(config.root, tree.dragging, node.id, node.children.length) }); tree.setDragging(null); tree.setDrop(null) } }}>
          <Button type="button" variant="outline" size="sm" onClick={() => add("condition")}><Plus data-icon="inline-start" aria-hidden="true" />Add {node.kind === "sequence" ? "stage" : "condition"}</Button>
          <div className="w-48"><Picker label="Add rule or group" value="add" choices={[["add", "Add rule / group…"], ...ruleKinds.filter(item => item.value !== "condition").map(item => [item.value, item.label])]} onChange={kind => { if (kind !== "add") add(kind as RuleKind) }} /></div>
          {tree.dragging && <Badge variant="outline">Drop into this group</Badge>}
          {tree.drop?.parent === node.id && tree.drop.index === node.children.length && <div data-filter-insertion-line aria-hidden="true" className="h-0.5 flex-1 bg-primary" />}
        </div>}
      </FieldGroup>}
    </FieldSet>
  </div>
}

export function MarketFilters(props: Props) {
  const { filters, draft: override, editor, onEditorChange, onDraftChange, metrics, combinations, combinationId } = props
  const formulaInput = useRef<HTMLTextAreaElement>(null)
  const [completionOpen, setCompletionOpen] = useState(false)
  const draft = override ?? filters
  const [saving, setSaving] = useState(false), [saveError, setSaveError] = useState(""), [feedback, setFeedback] = useState("")
  const nameDraft = editor.combinationName
  const setNameDraft = (value: { id: string; value: string } | null) => onEditorChange(current => ({ ...current, combinationName: value }))
  const [dragging, setDragging] = useState<string | null>(null), [drop, setDrop] = useState<{ parent: string; index: number } | null>(null)
  const selected = combinations.find(item => item.id === combinationId), name = nameDraft?.id === combinationId ? nameDraft.value : selected?.name ?? ""
  const dirty = override !== null || editor.source !== null
  const edit = (config: FilterConfigV2) => { onEditorChange(current => ({ ...current, source: null })); onDraftChange(config); setSaveError(""); setFeedback("") }
  const perform = async (action: () => Promise<void>, success: string) => {
    setSaving(true); setSaveError("")
    try { await action(); setFeedback(success) } catch (cause) { setSaveError(cause instanceof Error ? cause.message : "Cannot save filters.") } finally { setSaving(false) }
  }
  const load = (id: string) => { const combination = combinations.find(item => item.id === id); if (combination) void perform(async () => { await props.onSelectCombination(id); edit(parseFilterConfig(combination.filterConfigJSON ?? combination.filtersJSON)); setNameDraft(null) }, "Combination loaded for preview.") }
  const insertFormula = (expression: string) => {
    const source = editor.source ?? props.formula, start = formulaInput.current?.selectionStart ?? source.length, end = formulaInput.current?.selectionEnd ?? start
    onEditorChange(current => ({ ...current, source: source.slice(0, start) + expression + source.slice(end) }))
    setCompletionOpen(false)
    window.requestAnimationFrame(() => { formulaInput.current?.focus(); formulaInput.current?.setSelectionRange(start + expression.length, start + expression.length) })
  }
  const tree: TreeProps = { config: draft, edit, metrics, units: props.units, editor, setEditor: onEditorChange, disabled: saving, dragging, setDragging, drop, setDrop }
  return <Collapsible open={editor.open} onOpenChange={open => onEditorChange(current => ({ ...current, open }))} className="border-b px-4 py-3">
    <div className="flex items-center gap-3"><CollapsibleTrigger asChild><Button variant="ghost" size="sm"><Filter data-icon="inline-start" aria-hidden="true" />Filters<ChevronDown data-icon="inline-end" aria-hidden="true" className={cn(!editor.open && "-rotate-90")} /></Button></CollapsibleTrigger><Badge variant="outline">{ruleCount(draft.root)} conditions</Badge><span className="text-xs text-muted-foreground" role="status">{props.matches} / {props.total} markets · {props.unknown} Unknown{props.compiling ? " · Compiling…" : !props.valid ? " · Invalid draft" : props.previewPending ? " · Updating preview…" : dirty ? " · Draft preview" : " · Applied"}</span></div>
    <CollapsibleContent className="pt-3">
      <fieldset disabled={saving} className="flex flex-col gap-4"><legend className="sr-only">Market filter editor</legend>
        <FieldGroup className="grid grid-cols-[20rem_20rem_auto_auto_auto_minmax(0,1fr)] items-end gap-3">
          <Field><FieldLabel>Saved combinations</FieldLabel><div className="flex items-center gap-1"><Select value={selected?.id ?? ""} onValueChange={load} disabled={!combinations.length}><SelectTrigger className="w-full" aria-label="Saved combinations"><SelectValue placeholder="Choose a combination…" /></SelectTrigger><SelectContent position="popper"><SelectGroup>{combinations.map(item => <SelectItem key={item.id} value={item.id}>{item.name}</SelectItem>)}</SelectGroup></SelectContent></Select><Button type="button" variant="ghost" size="icon" disabled={!selected} aria-label="Reload selected combination" onClick={() => { if (selected) load(selected.id) }}><RotateCcw aria-hidden="true" /></Button></div></Field>
          <Field><FieldLabel>Combination name</FieldLabel><Input value={name} maxLength={80} aria-label="Combination name" placeholder="Name this combination…" onChange={event => setNameDraft({ id: combinationId, value: event.target.value })} /></Field>
          <Button type="button" variant="outline" disabled={!props.valid || !name.trim()} onClick={() => { void perform(async () => { await props.onSaveCombination(name.trim(), draft); setNameDraft(null) }, "Combination saved. Apply filters to confirm.") }}><Save data-icon="inline-start" aria-hidden="true" />{combinations.some(item => item.name.toLowerCase() === name.trim().toLowerCase()) ? "Update combination" : "Save combination"}</Button>
          <Button type="button" variant="ghost" disabled={!selected} aria-label="Delete combination" onClick={() => { if (selected) void perform(async () => { await props.onDeleteCombination(selected.id); setNameDraft(null) }, "Combination deleted; current rules remain.") }}><Trash2 aria-hidden="true" /></Button>
          <div className="w-60"><Picker label="Rule example" value="example" choices={[["example", "Start from an example…"], ...formulaExamples.map((item, i) => [String(i), item.label])]} onChange={value => { if (value !== "example") onEditorChange(current => ({ ...current, tab: "formula", source: formulaExamples[Number(value)].source })) }} /></div>
        </FieldGroup>
        <Tabs value={editor.tab} onValueChange={tab => onEditorChange(current => ({ ...current, tab: tab as "rules" | "formula" }))}><TabsList><TabsTrigger value="rules"><Filter data-icon="inline-start" aria-hidden="true" />Rules</TabsTrigger><TabsTrigger value="formula"><Code data-icon="inline-start" aria-hidden="true" />Formula</TabsTrigger></TabsList>
          <TabsContent value="rules" className="pt-2"><FieldGroup className="gap-3">
            <FieldSet><FieldLegend>Named formulas</FieldLegend><FieldDescription>Reuse numeric or category expressions throughout this combination.</FieldDescription><FieldGroup className="mt-2 gap-2">{draft.definitions.map(item => <FieldGroup key={item.id} className="grid grid-cols-[16rem_minmax(0,1fr)_auto] items-start gap-3"><Field><FieldLabel>Formula name</FieldLabel><Input value={item.name} aria-label="Formula name" spellCheck={false} onChange={event => edit({ ...draft, definitions: draft.definitions.map(current => current.id === item.id ? { ...current, name: event.target.value } : current) })} /></Field><ExpressionInput label="Formula expression" value={item.expression} metrics={metrics} units={props.units} definitions={draft.definitions.filter(current => current.id !== item.id)} onChange={expression => edit({ ...draft, definitions: draft.definitions.map(current => current.id === item.id ? { ...current, expression } : current) })} /><Button type="button" variant="ghost" size="icon" className="mt-6" aria-label="Remove formula" onClick={() => edit({ ...draft, definitions: draft.definitions.filter(current => current.id !== item.id) })}><X aria-hidden="true" /></Button></FieldGroup>)}</FieldGroup><Button type="button" variant="outline" size="sm" className="mt-2" onClick={() => { let i = 1; while (draft.definitions.some(item => item.name === `formula${i}`)) i += 1; edit({ ...draft, definitions: [...draft.definitions, { id: newRuleID(), name: `formula${i}`, expression: "Price" }] }) }}><Plus data-icon="inline-start" aria-hidden="true" />Add named formula</Button></FieldSet>
            <RuleCard node={draft.root} tree={tree} />
            {!draft.root.children.length && <Empty><EmptyHeader><EmptyTitle>All contracts in the universe</EmptyTitle><EmptyDescription>No hidden turnover, spread, listing age, or symbol restrictions. Add a condition or use an example.</EmptyDescription></EmptyHeader></Empty>}
          </FieldGroup></TabsContent>
          <TabsContent value="formula" className="pt-2"><FieldGroup><Field data-invalid={props.diagnostics.length > 0}><FieldLabel>Rule formula</FieldLabel><Textarea ref={formulaInput} onKeyDown={event => { if (event.ctrlKey && event.key === " ") { event.preventDefault(); setCompletionOpen(true) } }} value={editor.source ?? props.formula} rows={12} aria-label="Rule formula" aria-invalid={props.diagnostics.length > 0} spellCheck={false} onChange={event => onEditorChange(current => ({ ...current, source: event.target.value }))} /><FieldDescription>Declare reusable values with let name = expression;. Use AND / OR / NOT, parentheses, parameterized indicators, and time functions. Closed shifts its argument back one hour.</FieldDescription></Field>
            <Popover open={completionOpen} onOpenChange={setCompletionOpen}><PopoverTrigger asChild><Button type="button" variant="outline" size="sm"><Plus data-icon="inline-start" aria-hidden="true" />Insert metric / function (Ctrl+Space)</Button></PopoverTrigger><PopoverContent className="w-[32rem] p-0"><Command><CommandInput placeholder="Search expressions…" /><CommandList><CommandEmpty>No expressions found.</CommandEmpty><CommandGroup heading="Named formulas">{draft.definitions.map(item => <CommandItem key={item.id} value={item.name} onSelect={() => insertFormula(item.name)}>{item.name}<span className="ml-auto text-muted-foreground">{props.units[item.name] ?? "value"}</span></CommandItem>)}</CommandGroup><CommandGroup heading="Functions">{props.functions.map(item => <CommandItem key={item} value={item} onSelect={() => insertFormula(item)}>{item}</CommandItem>)}</CommandGroup><CommandGroup heading="Metrics">{metrics.map(item => <CommandItem key={item.key} value={`${item.key} ${item.label}`} onSelect={() => insertFormula(item.key)}>{item.label}<span className="ml-auto text-muted-foreground">{item.unit}</span></CommandItem>)}</CommandGroup></CommandList></Command></PopoverContent></Popover>
          </FieldGroup></TabsContent>
        </Tabs>
        {props.diagnostics.length > 0 && <FieldError role="alert">{props.diagnostics.join(" ")} Last valid preview remains active.</FieldError>}
        <div className="flex items-center gap-2"><Button type="button" disabled={!props.valid || props.compiling} onClick={() => { void perform(async () => { await props.onApply(draft); onEditorChange(current => ({ ...current, source: null })) }, "Filters applied and saved.") }}>{saving ? <Spinner data-icon="inline-start" aria-hidden="true" /> : <Check data-icon="inline-start" aria-hidden="true" />}Apply filters</Button><Button type="button" variant="outline" disabled={!dirty} onClick={() => { onEditorChange(current => ({ ...current, source: null })); onDraftChange(null); setSaveError(""); setFeedback("Saved filters restored.") }}>Discard changes</Button><Button type="button" variant="ghost" onClick={() => edit(emptyFilterConfig())}>Reset draft</Button><span className="ml-auto text-xs text-muted-foreground">Required history: {props.requiredHours}h · only True matches</span></div>
      </fieldset>
      {props.history && props.history.pending > 0 && <p className="mt-2 text-xs text-muted-foreground" role="status">Loading rule history for {props.history.pending} contracts · {props.history.completed} completed. Results update as data arrives.</p>}
      {props.history?.error && <FieldError>{props.history.error} Available history remains usable.</FieldError>}
      {saveError && <FieldError role="alert">{saveError}</FieldError>}{feedback && <p className="mt-2 text-xs text-muted-foreground" role="status">{feedback}</p>}
    </CollapsibleContent>
  </Collapsible>
}
