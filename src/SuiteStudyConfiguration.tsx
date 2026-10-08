import { Field, FieldDescription, FieldGroup, FieldLabel, FieldLegend, FieldSet } from '@/components/ui/field'
import { Input } from '@/components/ui/input'
import { Button } from '@/components/ui/button'
import { Select, SelectContent, SelectGroup, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { defaultCapital, type SuiteCapital, type SuiteCapitalSettings, type SuiteExecution } from '@/suite-types'

export function SuiteExecutionFields({ value, onChange }: { value: SuiteExecution; onChange: (value: SuiteExecution) => void }) {
  return <FieldSet><FieldLegend>Execution policy</FieldLegend><FieldGroup className="grid grid-cols-2">
    <Field><FieldLabel>Opposite signal</FieldLabel><Select value={value.opposite} onValueChange={opposite => onChange({ ...value,opposite: opposite as SuiteExecution['opposite'] })}><SelectTrigger aria-label="Opposite signal policy"><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="exitThenWait">Exit then wait</SelectItem><SelectItem value="reverse">Reverse at next open</SelectItem><SelectItem value="dedicatedOnly">Dedicated exits only</SelectItem></SelectGroup></SelectContent></Select><FieldDescription>Exit then wait requires another completed-hour confirmation before the opposite entry.</FieldDescription></Field>
    <Field><FieldLabel>Re-entry</FieldLabel><Select value={value.entry} onValueChange={entry => onChange({ ...value,entry: entry as SuiteExecution['entry'] })}><SelectTrigger aria-label="Re-entry policy"><SelectValue /></SelectTrigger><SelectContent><SelectGroup><SelectItem value="newPhaseEntry">New phase entry</SelectItem><SelectItem value="matchWhileFlat">Match while flat</SelectItem></SelectGroup></SelectContent></Select><FieldDescription>New phase entry requires a new episode. Unknown does not reset an existing match.</FieldDescription></Field>
  </FieldGroup></FieldSet>
}
const fields = [
  { key: 'initial', label: 'Initial capital (USDT)', factor: 1 }, { key: 'allocation', label: 'Position margin (%)', factor: 100 },
  { key: 'leverage', label: 'Leverage (×)', factor: 1 }, { key: 'maintenanceRate', label: 'Maintenance margin (%)', factor: 100 },
  { key: 'liquidationFeeBps', label: 'Liquidation fee (bps)', factor: 1 },
] as const
function CapitalFields({ prefix, value, onChange }: { prefix: string; value: SuiteCapitalSettings; onChange: (value: SuiteCapitalSettings) => void }) {
  return <FieldGroup className="grid grid-cols-5">{fields.map(f => <Field key={f.key}><FieldLabel htmlFor={prefix+f.key}>{f.label}</FieldLabel><Input id={prefix+f.key} name={prefix+f.key} type="number" step="any" inputMode="decimal" value={value[f.key] == null ? '' : value[f.key]! * f.factor} placeholder={f.key === 'maintenanceRate' || f.key === 'liquidationFeeBps' ? 'Required…' : undefined} onChange={e => onChange({ ...value,[f.key]: e.target.value.trim() ? Number(e.target.value)/f.factor : null })} /></Field>)}</FieldGroup>
}
export function SuiteCapitalFields({ value, onChange }: { value: SuiteCapital; onChange: (value: SuiteCapital) => void }) {
  return <FieldSet><FieldLegend>Independent per-contract capital</FieldLegend><FieldDescription>Each contract has its own account and one position. Initial defaults: 10,000 USDT, 100% margin, 1×. Enter maintenance and liquidation fees explicitly. Simplified isolated liquidation uses hourly traded OHLC.</FieldDescription><CapitalFields prefix="capital-" value={value.defaults} onChange={defaults => onChange({ ...value,defaults })} />
    {Object.entries(value.overrides).map(([symbol, settings]) => <FieldSet key={symbol}><FieldLegend>{symbol}</FieldLegend><CapitalFields prefix={symbol+'-'} value={settings} onChange={settings => onChange({ ...value,overrides: { ...value.overrides,[symbol]: settings } })} /><Button type="button" variant="ghost" onClick={() => { const overrides = { ...value.overrides }; delete overrides[symbol]; onChange({ ...value,overrides }) }}>Remove override</Button></FieldSet>)}
    <Field><FieldLabel htmlFor="override-symbol">Add a contract override</FieldLabel><Input id="override-symbol" name="overrideSymbol" placeholder="BTC-USDT-SWAP…" onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); const symbol = e.currentTarget.value.trim().toUpperCase(); if (symbol.endsWith('-USDT-SWAP')) { onChange({ ...value,overrides: { ...value.overrides,[symbol]: { ...value.defaults } } }); e.currentTarget.value = '' } } }} /><FieldDescription>Press Enter to add; all other contracts use the shared defaults independently.</FieldDescription></Field>
    <Button type="button" variant="ghost" onClick={() => onChange(defaultCapital())}>Reset capital parameters</Button>
  </FieldSet>
}
