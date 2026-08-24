const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const Model = require('../Model.js')

function sourcePayload(overrides = {}) {
  return JSON.stringify({
    schemaVersion: 1,
    source: {
      id: 'iromihon-themes-a1b2c3d4e5f6',
      url: 'https://github.com/RegionallyFamous/iromihon-themes.git',
      path: '/home/test/.local/share/omarchy/theme-sources/iromihon-themes-a1b2c3d4e5f6',
      commit: 'a'.repeat(40)
    },
    themes: [{
      slug: 'xerox-riot',
      name: 'Xerox Riot',
      path: '/home/test/.local/share/omarchy/theme-sources/iromihon-themes-a1b2c3d4e5f6/themes/xerox-riot',
      preview: '/home/test/.local/share/omarchy/theme-sources/iromihon-themes-a1b2c3d4e5f6/themes/xerox-riot/preview.png',
      wallpapers: [
        '/home/test/.local/share/omarchy/theme-sources/iromihon-themes-a1b2c3d4e5f6/themes/xerox-riot/backgrounds/1-primary.webp',
        '/home/test/.local/share/omarchy/theme-sources/iromihon-themes-a1b2c3d4e5f6/themes/xerox-riot/backgrounds/2-event.webp'
      ],
      status: 'available',
      installed: false,
      conflict: false,
      mode: 'dark',
      capabilities: { wallpaperCount: 2, unlock: true, icons: true, keyboard: true, shell: true, shellSurfaceCount: 4 },
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
  assert.equal(parsed.themes[0].wallpapers.length, 2)
  assert.equal(parsed.themes[0].capabilities.wallpaperCount, 2)
  assert.equal(parsed.themes[0].capabilities.shellSurfaceCount, 4)
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

test('restores an exact saved child and distinguishes first launch from source entry', () => {
  const firstLaunch = Model.parseRestoreJson(JSON.stringify({ schemaVersion: 1, selection: null, useDefault: true }))
  assert.deepEqual(firstLaunch, { ok: true, found: false, useDefault: true, error: '' })

  const sourceEntry = Model.parseRestoreJson(JSON.stringify({ schemaVersion: 1, selection: null, useDefault: false }))
  assert.deepEqual(sourceEntry, { ok: true, found: false, useDefault: false, error: '' })
  assert.equal(Model.parseRestoreJson(JSON.stringify({ schemaVersion: 1, selection: null, useDefault: 'yes' })).ok, false)

  const restored = Model.parseRestoreJson(sourcePayload({
    selection: {
      url: 'https://github.com/RegionallyFamous/iromihon-themes.git',
      slug: 'xerox-riot'
    }
  }))
  assert.equal(restored.ok, true)
  assert.equal(restored.found, true)
  assert.equal(restored.useDefault, false)
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
      url: 'https://github.com/RegionallyFamous/iromihon-themes.git',
      slug: 'not-in-source'
    }
  })
  assert.equal(Model.parseRestoreJson(absent).ok, false)

  const valid = sourcePayload({
    selection: {
      url: 'https://github.com/RegionallyFamous/iromihon-themes.git',
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

test('bounds wallpaper paths and derives fixed capability labels', () => {
  const payload = JSON.parse(sourcePayload())
  const themePath = payload.themes[0].path
  payload.themes[0].wallpapers = Array.from({ length: Model.MAX_WALLPAPERS + 3 }, (_, index) =>
    `${themePath}/backgrounds/${String(index + 1).padStart(2, '0')}.webp`)
  payload.themes[0].wallpapers[1] = '/tmp/escaping.webp'
  payload.themes[0].wallpapers[2] = `${themePath}/preview.png`
  payload.themes[0].capabilities.shellSurfaceCount = 999

  const parsed = Model.parseSourceJson(JSON.stringify(payload))
  assert.equal(parsed.ok, true)
  assert.equal(parsed.themes[0].wallpapers.length, Model.MAX_WALLPAPERS)
  assert.equal(parsed.themes[0].wallpapers.includes('/tmp/escaping.webp'), false)
  assert.equal(parsed.themes[0].capabilities.wallpaperCount, Model.MAX_WALLPAPERS)
  assert.equal(parsed.themes[0].capabilities.shellSurfaceCount, 16)
  assert.equal(Model.wallpaperPath(parsed.themes[0], 99), parsed.themes[0].wallpapers.at(-1))
  assert.deepEqual(Model.capabilityLabels(parsed.themes[0]), [
    'DARK', '12 WALLPAPERS', 'UNLOCK', 'SHELL ×16', 'ICONS', 'KEYBOARD'
  ])
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

test('renders every QML text surface as plain text', () => {
  const qml = fs.readFileSync(path.join(__dirname, '..', 'Iromihon.qml'), 'utf8')
  const textBlocks = qml.match(/\bText\s*\{[\s\S]*?\n\s*\}/g) || []

  assert.equal(textBlocks.length, 16)
  for (const block of textBlocks) assert.match(block, /textFormat:\s*Text\.PlainText/)
})
