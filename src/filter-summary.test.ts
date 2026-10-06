import assert from 'node:assert/strict'
import test from 'node:test'
import { filterConfigurationName, filterRuleSummary } from './filter-summary.ts'
import { cloneRule, emptyFilterConfig, makeRule, type FilterCombination } from './rule-engine.ts'

test('the current configuration matches saved contents despite JSON key order and new rule identities', () => {
  const config = emptyFilterConfig(), condition = makeRule()
  condition.left = 'Close'; condition.right = '100'; config.root.children = [condition]
  const saved = { definitions: [], root: cloneRule(config.root), version: 2 }
  const combinations: FilterCombination[] = [{ id: 'saved', name: 'Price breakout', filtersJSON: JSON.stringify(saved) }]
  assert.equal(filterConfigurationName(config, combinations, 'saved'), 'Price breakout')
  condition.right = '200'
  assert.equal(filterConfigurationName(config, combinations, 'saved'), 'Custom filters', 'Selecting a combination must not label different active rules with its name')
  config.root.children = []
  assert.equal(filterConfigurationName(config, combinations, 'saved'), 'All markets')
})

test('summaries show nested matching logic, thresholds, and closed time windows', () => {
  const config = emptyFilterConfig(), group = makeRule('any'), window = makeRule('every'), price = makeRule(), volume = makeRule()
  price.left = 'Close'; price.right = '100'
  volume.left = 'Volume'; volume.right = '200'
  window.mode = 'closed'; window.hours = 48; window.children = [price]
  group.children = [window, volume]; config.root.children = [group]
  assert.equal(filterRuleSummary(config, [], {}), '(Closed (Close ≥ 100 · every hour for 48h) OR Volume ≥ 200)')
})
