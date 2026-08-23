const test = require('node:test')
const assert = require('node:assert/strict')
const Model = require('../Model.js')

function sourcePayload(overrides = {}) {
  return JSON.stringify({
    schemaVersion: 1,
    source: {
      id: 'omarchy-chaos-themes-a1b2c3d4e5f6',
      url: 'https://github.com/RegionallyFamous/omarchy-chaos-themes.git',
      path: '/home/test/.local/share/omarchy/theme-sources/omarchy-chaos-themes-a1b2c3d4e5f6',
      commit: 'a'.repeat(40)
    },
    themes: [{
      slug: 'xerox-riot',
      name: 'Xerox Riot',
      path: '/home/test/.local/share/omarchy/theme-sources/omarchy-chaos-themes-a1b2c3d4e5f6/themes/xerox-riot',
      preview: '/home/test/.local/share/omarchy/theme-sources/omarchy-chaos-themes-a1b2c3d4e5f6/themes/xerox-riot/preview.png',
      status: 'available',
      installed: false,
      conflict: false,
      mode: 'dark',
      colors: { background: '#12110f', foreground: '#e8dec8', accent: '#ff3366' }
    }],
    ...overrides
  })
}

test('accepts only public GitHub HTTPS repository URLs', () => {
  assert.deepEqual(Model.validateRepositoryUrl('https://github.com/RegionallyFamous/chaos.git#xerox-riot'), {
    ok: true,
    baseUrl: 'https://github.com/RegionallyFamous/chaos.git',
    selector: 'xerox-riot',
    error: ''
  })
  assert.equal(Model.validateRepositoryUrl('git@github.com:owner/repo.git').ok, false)
  assert.equal(Model.validateRepositoryUrl('https://token@github.com/owner/repo.git').ok, false)
  assert.equal(Model.validateRepositoryUrl('https://example.com/owner/repo.git').ok, false)
})

test('parses a bounded source response and preserves safe native paths', () => {
  const parsed = Model.parseSourceJson(sourcePayload())
  assert.equal(parsed.ok, true)
  assert.equal(parsed.themes[0].slug, 'xerox-riot')
  assert.equal(parsed.themes[0].colors.accent, '#ff3366')
  assert.equal(Model.fileUrl(parsed.themes[0].preview).startsWith('file:///home/test/'), true)
})

test('rejects malformed, oversized, and escaping source data', () => {
  assert.equal(Model.parseSourceJson('{').ok, false)
  const payload = sourcePayload()
  const exactBoundary = ' '.repeat(Model.MAX_JSON_CHARS - payload.length) + payload
  assert.equal(exactBoundary.length, Model.MAX_JSON_CHARS)
  assert.equal(Model.parseSourceJson(exactBoundary).ok, true)
  assert.equal(Model.parseSourceJson(' ' + exactBoundary).ok, false)

  const escaping = JSON.parse(sourcePayload())
  escaping.themes[0].path = '/tmp/outside'
  assert.equal(Model.parseSourceJson(JSON.stringify(escaping)).ok, false)
})

test('restores an exact saved child and recognizes first launch', () => {
  const firstLaunch = Model.parseRestoreJson(JSON.stringify({ schemaVersion: 1, selection: null }))
  assert.deepEqual(firstLaunch, { ok: true, found: false, error: '' })

  const restored = Model.parseRestoreJson(sourcePayload({
    selection: {
      url: 'https://github.com/RegionallyFamous/omarchy-chaos-themes.git',
      slug: 'xerox-riot'
    }
  }))
  assert.equal(restored.ok, true)
  assert.equal(restored.found, true)
  assert.equal(restored.slug, 'xerox-riot')
  assert.equal(restored.themes[0].slug, 'xerox-riot')
})

test('rejects mismatched, absent, and oversized saved selections', () => {
  const mismatched = sourcePayload({
    selection: { url: 'https://github.com/another/source.git', slug: 'xerox-riot' }
  })
  assert.equal(Model.parseRestoreJson(mismatched).ok, false)

  const absent = sourcePayload({
    selection: {
      url: 'https://github.com/RegionallyFamous/omarchy-chaos-themes.git',
      slug: 'not-in-source'
    }
  })
  assert.equal(Model.parseRestoreJson(absent).ok, false)

  const valid = sourcePayload({
    selection: {
      url: 'https://github.com/RegionallyFamous/omarchy-chaos-themes.git',
      slug: 'xerox-riot'
    }
  })
  const exactBoundary = ' '.repeat(Model.MAX_JSON_CHARS - valid.length) + valid
  assert.equal(Model.parseRestoreJson(exactBoundary).ok, true)
  assert.equal(Model.parseRestoreJson(' ' + exactBoundary).ok, false)
})

test('caps theme records before they enter the QML model', () => {
  const payload = JSON.parse(sourcePayload())
  payload.themes = Array.from({ length: 129 }, (_, index) => ({
    ...payload.themes[0],
    slug: `theme-${index}`,
    name: `Theme ${index}`,
    path: `${payload.source.path}/themes/theme-${index}`,
    preview: ''
  }))
  const parsed = Model.parseSourceJson(JSON.stringify(payload))
  assert.equal(parsed.ok, true)
  assert.equal(parsed.themes.length, 128)
})

test('wraps navigation and selects deep-linked children', () => {
  const themes = [{ slug: 'one' }, { slug: 'two' }, { slug: 'three' }]
  assert.equal(Model.selectedIndex(themes, 'two', 0), 1)
  assert.equal(Model.adjacentIndex(3, 2, 1), 0)
  assert.equal(Model.adjacentIndex(3, 0, -1), 2)
})

test('builds a compact unique palette and honest status labels', () => {
  const theme = { installed: false, conflict: false, colors: { background: '#000000', foreground: '#ffffff', accent: '#ffffff' } }
  assert.deepEqual(Model.palette(theme), ['#000000', '#ffffff'])
  assert.equal(Model.statusLabel(theme), 'NOT INSTALLED')
  assert.equal(Model.statusLabel({ conflict: true }), 'NAME CONFLICT')
  assert.equal(Model.statusLabel({ installed: true }), 'INSTALLED')
})

test('encodes preview paths without turning filename punctuation into URL syntax', () => {
  assert.equal(Model.fileUrl('/tmp/theme/preview #1?.png'), 'file:///tmp/theme/preview%20%231%3F.png')
  assert.equal(Model.fileUrl('relative/preview.png'), '')
})
