import { useId, useRef, useState } from "react"
import { ChevronDown, Search } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import { Command, CommandEmpty, CommandGroup, CommandInput, CommandItem, CommandList } from "@/components/ui/command"
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { cn } from "@/lib/utils"
import { arithmeticExpression, arithmeticOperations, expressionName, expressionSource, expressionTemplates, numberExpression, rawExpression, templateExpression, withExpressionArguments } from "@/filter-expression"
import type { EditorExpression, FilterMetric, NamedFormula } from "@/rule-engine"

export type ExpressionInputProps = {
  label: string; displayLabel?: string; value: string; onChange: (value: string, expression?: EditorExpression) => void; onSelectExpression?: (value: string) => void
  metrics: FilterMetric[]; definitions: NamedFormula[]; choices?: { value: string; label: string }[]; unit?: string
  units?: Record<string, string>; expressions?: Record<string, EditorExpression>; expression?: EditorExpression
}
function ExpressionSelect({ label, value, choices, onChange }: { label: string; value: string; choices: string[][]; onChange: (value: string) => void }) {
  return <Select value={value} onValueChange={onChange}><SelectTrigger className="w-full" aria-label={label}><SelectValue /></SelectTrigger><SelectContent position="popper"><SelectGroup>{choices.map(([key, title]) => <SelectItem key={key} value={key}>{title}</SelectItem>)}</SelectGroup></SelectContent></Select>
}

export function ExpressionInput({ label, displayLabel = label, value, onChange, onSelectExpression, metrics, definitions, choices = [], unit, units = {}, expressions = {}, expression }: ExpressionInputProps) {
  const [open, setOpen] = useState(false), [partsOpen, setPartsOpen] = useState(true)
  const [edited, setEdited] = useState<EditorExpression | null>(null)
  const fieldID = useId()
  const input = useRef<HTMLInputElement>(null)
  const reading = metrics.find(metric => metric.key.toLowerCase() === value.trim().toLowerCase())
  const resolved = expressions[value] ?? expression
  const tree = resolved && resolved.kind !== "raw" ? resolved : edited?.source === value ? edited : resolved ?? rawExpression(value, reading?.unit ?? units[value] ?? "")
  const template = expressionTemplates.find(item => item.name.toLowerCase() === expressionName(tree))
  const numericConstant = Number.isFinite(Number(value)) && Boolean(value.trim()) || resolved?.unit === "constant"
  const resolvedUnit = reading?.unit ?? resolved?.unit ?? units[value] ?? (tree.unit === "source unit" ? "" : tree.unit)
  const description = numericConstant ? unit ? `${unit} (constant)` : "Numeric constant" : resolvedUnit || unit || "Enter an expression to resolve its unit"
  const changeTree = (next: EditorExpression, selecting = false) => {
    next = { ...next, source: expressionSource(next) }; setEdited(next); setPartsOpen(true)
    if (selecting && onSelectExpression) onSelectExpression(next.source)
    else onChange(next.source, next)
  }
  const insert = (next: EditorExpression) => { changeTree(next, true); setOpen(false); window.requestAnimationFrame(() => input.current?.focus()) }
  const shared = { metrics, definitions, units, expressions }
  const wrappers = expressionTemplates.filter(item => item.parameters[0].kind === "expression" && (!["category", "text"].includes(resolvedUnit) || ["closed", "live"].includes(item.name)))
  const hasParts = ["binary", "unary"].includes(tree.kind) || tree.kind === "call" && template
  return <FieldGroup className="gap-2">
    <Field>
      <FieldLabel htmlFor={fieldID}>{displayLabel}</FieldLabel>
      <div className="flex items-center gap-1">
        <Input id={fieldID} ref={input} value={value} onChange={event => { setEdited(null); onChange(event.target.value) }} onKeyDown={event => { if (event.key === " " && event.ctrlKey) { event.preventDefault(); setOpen(true) } }} aria-label={label} autoComplete="off" spellCheck={false} />
        <Popover open={open} onOpenChange={setOpen}>
          <PopoverTrigger asChild><Button type="button" variant="outline" size="icon" aria-label={`Choose ${label}`} title="Find a metric or function (Ctrl+Space)"><Search aria-hidden="true" /></Button></PopoverTrigger>
          <PopoverContent className="w-[28rem] p-0" align="start"><Command>
            <CommandInput placeholder="Find a metric, function, or named formula…" />
            <CommandList><CommandEmpty>No matching expressions.</CommandEmpty>
              {choices.length > 0 && <CommandGroup heading="Values">{choices.map(choice => <CommandItem key={choice.value} value={`value ${choice.label}`} onSelect={() => insert({ ...rawExpression(JSON.stringify(choice.value), "category"), kind: "text", value: choice.value })}>{choice.label}</CommandItem>)}</CommandGroup>}
              {["Parameterized indicators", "Expression functions"].map(group => <CommandGroup key={group} heading={group}>{expressionTemplates.filter(item => item.group === group).map(item => <CommandItem key={item.name} value={`${item.label} ${item.name}`} onSelect={() => insert(templateExpression(item))}>{item.label}<span className="ml-auto text-muted-foreground">{item.unit}</span></CommandItem>)}</CommandGroup>)}
              <CommandGroup heading="Arithmetic">{arithmeticOperations.map(([operation, title]) => <CommandItem key={operation} value={`arithmetic ${title}`} onSelect={() => insert(arithmeticExpression(operation))}>{title}</CommandItem>)}</CommandGroup>
              {definitions.length > 0 && <CommandGroup heading="Named formulas / earlier captures">{definitions.map(item => <CommandItem key={item.id} value={item.name} onSelect={() => insert(expressions[item.name] ?? { ...rawExpression(item.name, units[item.name]), kind: "name", value: item.name })}>{item.name}<span className="ml-auto text-muted-foreground">{units[item.name] ?? "value"}</span></CommandItem>)}</CommandGroup>}
              {[...new Set(metrics.map(metric => metric.group))].map(group => <CommandGroup key={group} heading={group}>{metrics.filter(metric => metric.group === group).map(metric => <CommandItem key={metric.key} value={`${metric.label} ${metric.key}`} onSelect={() => insert({ ...rawExpression(metric.key, metric.unit), kind: "name", value: metric.key, choices: metric.choices })}>{metric.label}<span className="ml-auto text-muted-foreground">{metric.unit}</span></CommandItem>)}</CommandGroup>)}
            </CommandList>
          </Command></PopoverContent>
        </Popover>
      </div>
      <FieldDescription>{description}{reading?.description && <span className="block">{reading.description}</span>}</FieldDescription>
    </Field>
    <div className="max-w-64"><ExpressionSelect label={`Transform ${label}`} value="transform" choices={[["transform", "Transform expression…"], ...wrappers.map(item => [item.name, item.label]), ...(!["category", "text"].includes(resolvedUnit) ? arithmeticOperations : [])]} onChange={operation => {
      if (operation === "transform") return
      const wrapper = expressionTemplates.find(item => item.name === operation)
      changeTree(wrapper ? templateExpression(wrapper, tree) : arithmeticExpression(operation, tree))
    }} /></div>
    {hasParts && <Collapsible open={partsOpen} onOpenChange={setPartsOpen} className="rounded-lg border p-2">
      <CollapsibleTrigger asChild><Button type="button" variant="ghost" size="sm" aria-label={`Toggle ${label} parameters`} aria-expanded={partsOpen}><ChevronDown data-icon="inline-start" aria-hidden="true" className={cn(!partsOpen && "-rotate-90")} />{template?.label ?? "Arithmetic"} parameters</Button></CollapsibleTrigger>
      <CollapsibleContent><FieldGroup className="mt-2 gap-2">
        {template && tree.kind === "call" && <>
          {template.parameters.map((parameter, index) => parameter.kind === "number" ? <Field key={index}>
            <FieldLabel htmlFor={`${fieldID}-${index}`}>{parameter.label}</FieldLabel><Input id={`${fieldID}-${index}`} type="number" min={parameter.minimum} step={parameter.step} value={tree.arguments[index]?.value ?? tree.arguments[index]?.source ?? ""} aria-label={`${label} ${parameter.label}`} onChange={event => changeTree(withExpressionArguments(tree, index, numberExpression(event.target.value)))} /><FieldDescription>{parameter.unit}</FieldDescription>
          </Field> : <ExpressionInput key={index} label={`${label} ${parameter.label}`} displayLabel={parameter.label} value={tree.arguments[index]?.source ?? ""} expression={tree.arguments[index]} onChange={(next, nextTree) => changeTree(withExpressionArguments(tree, index, nextTree ?? rawExpression(next)))} {...shared} />)}
          <FieldDescription>{template.description}</FieldDescription>
        </>}
        {tree.kind === "binary" && <>
          <Field><FieldLabel>Operation</FieldLabel><ExpressionSelect label={`${label} Operation`} value={tree.operation ?? "+"} choices={arithmeticOperations} onChange={operation => changeTree({ ...tree, operation })} /></Field>
          {tree.arguments.map((argument, index) => <ExpressionInput key={index} label={`${label} ${index === 0 ? "Left operand" : "Right operand"}`} displayLabel={index === 0 ? "Left operand" : "Right operand"} value={argument.source} expression={argument} onChange={(next, nextTree) => changeTree(withExpressionArguments(tree, index, nextTree ?? rawExpression(next)))} {...shared} />)}
        </>}
        {tree.kind === "unary" && <>
          <Field><FieldLabel>Sign</FieldLabel><ExpressionSelect label={`${label} Sign`} value={tree.operation ?? "+"} choices={[["+", "Positive +"], ["-", "Negative −"]]} onChange={operation => changeTree({ ...tree, operation })} /></Field>
          <ExpressionInput label={`${label} Source expression`} displayLabel="Source expression" value={tree.arguments[0].source} expression={tree.arguments[0]} onChange={(next, nextTree) => changeTree(withExpressionArguments(tree, 0, nextTree ?? rawExpression(next)))} {...shared} />
        </>}
      </FieldGroup></CollapsibleContent>
    </Collapsible>}
  </FieldGroup>
}
