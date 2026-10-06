import assert from 'node:assert/strict'
import test from 'node:test'
import { addLibraryRule, anchorOffset, bodyPresentation, captureScope, conditionLibrary, renameValueReferences, ruleSentence, topLevelSelection, visualPresets } from './filter-builder.ts'
import { arithmeticExpression, rawExpression } from './filter-expression.ts'
import { emptyFilterConfig, makeRule, type FilterMetric } from './rule-engine.ts'

const metrics: FilterMetric[] = [{ key: 'oiTrend', label: 'OI Trend', group: 'Open interest', description: 'Compare hourly OI.', unit: 'category', numeric: false, choices: [{ value: 'rising', label: 'Rising' }] }]
test('ready-to-use rules encode complete windows, closed anchors and frozen event references', () => {
  const preset = (id: string) => visualPresets.find(p => p.id === id)!.create()
  const body = preset('preset:body')
  assert.equal(body.mode, 'closed'); assert.equal(body.kind, 'every'); assert.equal(body.hours, 48)
  assert.deepEqual(body.children[0].children.map(n => [n.left, n.comparison, n.right, n.mode]), [['Open', 'gt', 'EMA(200)', 'live'], ['Close', 'gt', 'EMA(200)', 'live']])
  assert.equal(preset('preset:volume').right, '(mean(lag(Volume, 1), 20) * 2)')
  const rsi = preset('preset:rsi'); assert.equal(rsi.mode, 'closed'); assert.equal(rsi.hours, 3)
  const sequence = preset('preset:sequence')
  assert.equal(sequence.hours, 6)
  assert.equal(sequence.children[0].captures[0].expression, 'PriorHigh(48)')
  assert.equal(sequence.children[1].right, 'break.level'); assert.equal(sequence.children[2].kind, 'crossup')
  assert.deepEqual(captureScope(sequence, sequence.children[2].id)?.map(c => c.name), ['break.level'])
})
test('library additions honor the selected group and preserve unrelated rules and settings', () => {
  const cfg = emptyFilterConfig(), group = makeRule('any'); cfg.root.children = [group]
  const item = conditionLibrary(metrics).find(i => i.id === 'metric:oiTrend')!
  const next = addLibraryRule(cfg, group.id, item)
  assert.equal(next.config.root.children[0].children[0].id, next.selectedId)
  assert.equal(next.config.root.children[0].children[0].right, '"rising"')
  assert.equal(cfg.root.children[0].children.length, 0)
  assert.equal(next.config.root.kind, 'all')
  assert.equal(new Set(conditionLibrary(metrics).map(i => i.id)).size, conditionLibrary(metrics).length)
})
test('summaries retain the selected time semantics and bulk operations do not double-apply ancestors', () => {
  const root = makeRule('all'), group = makeRule('every'), child = makeRule()
  root.mode = 'closed'; group.mode = 'closed'; group.hours = 48; child.left = 'oiTrend'; child.comparison = 'eq'; child.right = '"rising"'
  group.children = [child]; root.children = [group]
  assert.equal(anchorOffset(root, child.id), 2)
  assert.match(ruleSentence(group, metrics, {}), /OI Trend is Rising · every hour for 48h/)
  assert.deepEqual(topLevelSelection(root, [root.id, group.id, child.id]), [])
  assert.deepEqual(topLevelSelection(root, [group.id, child.id]), [group.id])
})
test('editing an empty body period retains the specialized visual controls for repairing invalid drafts', () => {
  const body = visualPresets.find(p => p.id === 'preset:body')!.create().children[0]
  body.children.forEach(c => c.right = 'EMA()')
  assert.deepEqual(bodyPresentation(body), { period: '', direction: 'above' })
  body.children[1].mode = 'closed'
  assert.equal(bodyPresentation(body), null, 'A distinct child anchor must never be hidden by a composite control')
})
test('renaming captured values updates parsed references and preserves matching literal text', () => {
  const cfg = emptyFilterConfig(), rule = makeRule()
  rule.left = '(break.level * 2)'; rule.right = '"break.level"'; cfg.root.children = [rule]
  const tree = arithmeticExpression('*', { ...rawExpression('break.level', 'USDT'), kind: 'name', value: 'break.level' })
  const renamed = renameValueReferences(cfg, { 'break.level': 'break.reference' }, { [rule.left]: tree, [rule.right]: { ...rawExpression(rule.right, 'text'), kind: 'text', value: 'break.level' } })
  assert.equal(renamed.root.children[0].left, '(break.reference * 2)')
  assert.equal(renamed.root.children[0].right, '"break.level"')
  assert.equal(cfg.root.children[0].left, '(break.level * 2)')
})
