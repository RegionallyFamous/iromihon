var MAX_JSON_CHARS = 262144
var MAX_URL_CHARS = 512
var MAX_PATH_CHARS = 512
var MAX_NAME_CHARS = 80
var MAX_THEMES = 128

function isValidSlug(value) {
  var slug = String(value || "")
  return /^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)
}

function isValidSourceId(value) {
  var id = String(value || "")
  return /^[a-z0-9]+(?:-[a-z0-9]+)*-[a-f0-9]{12}$/.test(id)
}

function validateRepositoryUrl(value) {
  var input = String(value || "").trim()
  if (!input) return { ok: false, error: "Paste a public GitHub repository URL." }
  if (input.length > MAX_URL_CHARS) return { ok: false, error: "Repository URL is too long." }
  if (/\s/.test(input)) return { ok: false, error: "Repository URL cannot contain whitespace." }

  var match = input.match(/^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?(?:#([a-z0-9]+(?:-[a-z0-9]+)*))?$/)
  if (!match) return { ok: false, error: "Use a public https://github.com/owner/repository URL." }

  var owner = match[1]
  var repository = match[2]
  var selector = match[3] || ""
  if (!owner || !repository || owner === "." || owner === ".." || repository === "." || repository === "..")
    return { ok: false, error: "Repository owner and name are invalid." }

  return {
    ok: true,
    baseUrl: "https://github.com/" + owner + "/" + repository + ".git",
    selector: selector,
    error: ""
  }
}

function boundedString(value, max) {
  var text = String(value == null ? "" : value)
  return text.length <= max ? text : ""
}

function safeAbsolutePath(value) {
  var path = boundedString(value, MAX_PATH_CHARS)
  if (!path || path.charAt(0) !== "/" || path.indexOf("\0") >= 0) return ""
  var parts = path.split("/")
  for (var i = 0; i < parts.length; i++) if (parts[i] === "..") return ""
  return path
}

function pathWithin(path, parent) {
  if (!path || !parent) return false
  return path === parent || path.indexOf(parent + "/") === 0
}

function safeColor(value) {
  var color = String(value || "").toLowerCase()
  return /^#[0-9a-f]{6}(?:[0-9a-f]{2})?$/.test(color) ? color : ""
}

function normalizeTheme(raw, sourcePath) {
  if (!raw || !isValidSlug(raw.slug)) return null
  var path = safeAbsolutePath(raw.path)
  if (!pathWithin(path, sourcePath)) return null

  var preview = safeAbsolutePath(raw.preview)
  if (preview && !pathWithin(preview, path)) preview = ""
  var status = String(raw.status || "available")
  if (status !== "available" && status !== "installed" && status !== "conflict") status = "available"
  var colors = raw.colors && typeof raw.colors === "object" ? raw.colors : {}

  return {
    slug: String(raw.slug),
    name: boundedString(raw.name || raw.slug, MAX_NAME_CHARS) || String(raw.slug),
    path: path,
    preview: preview,
    status: status,
    installed: raw.installed === true,
    conflict: raw.conflict === true,
    mode: raw.mode === "light" ? "light" : "dark",
    colors: {
      accent: safeColor(colors.accent),
      background: safeColor(colors.background),
      foreground: safeColor(colors.foreground),
      red: safeColor(colors.red),
      yellow: safeColor(colors.yellow),
      green: safeColor(colors.green),
      cyan: safeColor(colors.cyan),
      blue: safeColor(colors.blue),
      magenta: safeColor(colors.magenta)
    }
  }
}

function parseSourceJson(rawText) {
  var raw = String(rawText || "")
  if (!raw || raw.length > MAX_JSON_CHARS) return { ok: false, error: "Theme source response was empty or too large." }

  var parsed
  try { parsed = JSON.parse(raw) } catch (e) { return { ok: false, error: "Theme source returned malformed data." } }
  if (!parsed || parsed.schemaVersion !== 1 || !parsed.source || !Array.isArray(parsed.themes))
    return { ok: false, error: "Theme source response has an unsupported shape." }

  var sourcePath = safeAbsolutePath(parsed.source.path)
  var sourceId = String(parsed.source.id || "")
  var sourceUrl = boundedString(parsed.source.url, MAX_URL_CHARS)
  var commit = String(parsed.source.commit || "")
  var validatedUrl = validateRepositoryUrl(sourceUrl)
  if (!isValidSourceId(sourceId) || !sourcePath || !/^[a-f0-9]{40}$/.test(commit) ||
      !validatedUrl.ok || validatedUrl.selector || validatedUrl.baseUrl !== sourceUrl)
    return { ok: false, error: "Theme source identity is invalid." }

  var source = { id: sourceId, url: sourceUrl, path: sourcePath, commit: commit }
  var themes = []
  for (var i = 0; i < parsed.themes.length && themes.length < MAX_THEMES; i++) {
    var theme = normalizeTheme(parsed.themes[i], sourcePath)
    if (theme) themes.push(theme)
  }
  if (themes.length === 0) return { ok: false, error: "This repository contains no valid native themes." }

  return { ok: true, source: source, themes: themes, error: "" }
}

function parseRestoreJson(rawText) {
  var raw = String(rawText || "")
  if (!raw || raw.length > MAX_JSON_CHARS) return { ok: false, error: "Saved selection response was empty or too large." }

  var decoded
  try { decoded = JSON.parse(raw) } catch (e) { return { ok: false, error: "Saved selection returned malformed data." } }
  if (!decoded || decoded.schemaVersion !== 1 || !("selection" in decoded))
    return { ok: false, error: "Saved selection response has an unsupported shape." }
  if (("useDefault" in decoded) && typeof decoded.useDefault !== "boolean")
    return { ok: false, error: "Saved selection response has an unsupported shape." }
  if (decoded.selection === null)
    return { ok: true, found: false, useDefault: decoded.useDefault === true, error: "" }
  if (!decoded.selection || typeof decoded.selection !== "object" || !isValidSlug(decoded.selection.slug))
    return { ok: false, error: "Saved selection identity is invalid." }

  var selectedUrl = validateRepositoryUrl(decoded.selection.url)
  var source = parseSourceJson(raw)
  if (!selectedUrl.ok || selectedUrl.selector || !source.ok || source.source.url !== selectedUrl.baseUrl)
    return { ok: false, error: source.ok ? "Saved selection identity is invalid." : source.error }
  if (!source.themes.some(function(theme) { return theme.slug === decoded.selection.slug }))
    return { ok: false, error: "The saved theme is no longer in this collection." }

  return {
    ok: true,
    found: true,
    source: source.source,
    themes: source.themes,
    slug: String(decoded.selection.slug),
    useDefault: false,
    error: ""
  }
}

function selectedIndex(themes, requestedSlug, fallbackIndex) {
  var list = Array.isArray(themes) ? themes : []
  var slug = String(requestedSlug || "")
  if (slug) for (var i = 0; i < list.length; i++) if (list[i].slug === slug) return i
  var fallback = Number(fallbackIndex)
  if (!isFinite(fallback)) fallback = 0
  return Math.max(0, Math.min(Math.max(0, list.length - 1), Math.floor(fallback)))
}

function adjacentIndex(length, index, direction) {
  var count = Math.max(0, Math.floor(Number(length) || 0))
  if (count === 0) return 0
  var current = Math.max(0, Math.min(count - 1, Math.floor(Number(index) || 0)))
  var delta = direction < 0 ? -1 : 1
  return (current + delta + count) % count
}

function palette(theme) {
  var colors = theme && theme.colors ? theme.colors : {}
  var order = ["background", "foreground", "red", "yellow", "green", "cyan", "blue", "magenta", "accent"]
  var result = []
  for (var i = 0; i < order.length; i++) {
    var color = safeColor(colors[order[i]])
    if (color && result.indexOf(color) < 0) result.push(color)
  }
  return result
}

function statusLabel(theme) {
  if (!theme) return "UNAVAILABLE"
  if (theme.conflict || theme.status === "conflict") return "NAME CONFLICT"
  if (theme.installed || theme.status === "installed") return "INSTALLED"
  return "NOT INSTALLED"
}

function fileUrl(path) {
  var value = safeAbsolutePath(path)
  if (!value) return ""
  return "file://" + value.split("/").map(function(segment) { return encodeURIComponent(segment) }).join("/")
}

if (typeof module !== "undefined") module.exports = {
  MAX_JSON_CHARS: MAX_JSON_CHARS,
  adjacentIndex: adjacentIndex,
  fileUrl: fileUrl,
  isValidSlug: isValidSlug,
  palette: palette,
  parseRestoreJson: parseRestoreJson,
  parseSourceJson: parseSourceJson,
  selectedIndex: selectedIndex,
  statusLabel: statusLabel,
  validateRepositoryUrl: validateRepositoryUrl
}
