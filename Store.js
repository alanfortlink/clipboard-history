.pragma library

// History store operations: normalization, dedup, pins, pruning.
// Pure ES5 — runs in QML (.pragma library) and node (tests).

var DEFAULT_LIMIT = 1500

// FNV-1a 32-bit, hex. Used for stable entry ids.
function hash32(s) {
  var h = 0x811c9dc5
  s = String(s || "")
  for (var i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = (h + (h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24)) >>> 0
  }
  return ("0000000" + h.toString(16)).slice(-8)
}

function entryKey(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "image:" + String(entry.path || "")
  if (entry.type === "files") return "files:" + (entry.paths || []).join("\n")
  return "text:" + String(entry.text || "")
}

function entryId(entry) {
  if (!entry) return ""
  if (entry.type === "image") return "img:" + hash32(String(entry.path || ""))
  if (entry.type === "files") return "files:" + hash32((entry.paths || []).join("\n"))
  return "txt:" + hash32(String(entry.text || "")) + ":" + String(entry.text || "").length
}

// Validate + fill defaults. Returns null for entries that should be dropped.
function normalize(value, now) {
  if (!value || typeof value !== "object") return null
  var type = String(value.type || "")
  var out = null

  if (type === "text") {
    var text = String(value.text || "")
    if (!text.trim()) return null
    out = { type: "text", text: text }
  } else if (type === "image") {
    var path = String(value.path || "")
    if (!path) return null
    out = {
      type: "image",
      path: path,
      mime: String(value.mime || "image/png")
    }
    if (value.w) out.w = Number(value.w)
    if (value.h) out.h = Number(value.h)
    if (value.qr) out.qr = String(value.qr)
  } else if (type === "files") {
    var paths = Array.isArray(value.paths) ? value.paths.filter(function(p) { return !!p }) : []
    if (paths.length === 0) return null
    out = { type: "files", paths: paths }
  } else {
    return null
  }

  var ts = Number(value.ts)
  out.ts = isFinite(ts) && ts > 0 ? Math.floor(ts) : (now || 0)
  var bytes = Number(value.bytes)
  out.bytes = isFinite(bytes) && bytes >= 0 ? Math.floor(bytes) : 0
  out.app = String(value.app || "")
  out.id = String(value.id || entryId(out))
  var uses = Number(value.uses)
  out.uses = isFinite(uses) && uses > 0 ? Math.floor(uses) : 0
  if (value.pinned) out.pinned = true
  return out
}

function parseHistory(raw, now) {
  try {
    var parsed = JSON.parse(String(raw || "[]"))
    var next = []
    if (!Array.isArray(parsed)) return next
    for (var i = 0; i < parsed.length; i++) {
      var e = normalize(parsed[i], now)
      if (e) next.push(e)
    }
    return next
  } catch (err) {
    return []
  }
}

// Add (or bump) an entry; newest first. Keeps pin state and usage count of
// the existing copy when the same content is copied again. Does NOT truncate
// to the limit: the caller prunes via prune() so evicted image blobs can be
// garbage-collected (truncating here would leak them).
function addEntry(history, entry, now) {
  var normalized = normalize(entry, now)
  if (!normalized) return Array.isArray(history) ? history.slice() : []

  var key = entryKey(normalized)
  var next = [normalized]
  var values = Array.isArray(history) ? history : []
  for (var i = 0; i < values.length; i++) {
    var existing = normalize(values[i], now)
    if (!existing) continue
    if (entryKey(existing) === key) {
      // Re-copy of existing content: keep its pin state and usage count.
      if (existing.pinned) normalized.pinned = true
      if (existing.uses > 0) normalized.uses = existing.uses
      // Keep expensive derived data (e.g. decoded QR) across re-captures.
      if (existing.qr && !normalized.qr) normalized.qr = existing.qr
      continue
    }
    next.push(existing)
  }
  return next
}

function findById(history, id) {
  var values = Array.isArray(history) ? history : []
  for (var i = 0; i < values.length; i++) {
    if (values[i] && values[i].id === id) return values[i]
  }
  return null
}

function removeById(history, id) {
  var values = Array.isArray(history) ? history : []
  var next = []
  for (var i = 0; i < values.length; i++) {
    if (values[i] && values[i].id === id) continue
    next.push(values[i])
  }
  return next
}

function togglePin(history, id) {
  var values = Array.isArray(history) ? history : []
  var entry = findById(values, id)
  if (!entry) return values
  if (entry.pinned) delete entry.pinned
  else entry.pinned = true
  return values
}

function touch(history, id, now) {
  var values = Array.isArray(history) ? history : []
  var entry = findById(values, id)
  if (!entry) return values
  entry.uses = (Number(entry.uses) || 0) + 1
  entry.ts = now || entry.ts
  // Move to front like a fresh copy would.
  var next = [entry]
  for (var i = 0; i < values.length; i++) {
    if (values[i] !== entry) next.push(values[i])
  }
  return next
}

// Enforce the limit. Returns { entries, droppedImagePaths } so the caller can
// garbage-collect image blobs.
function prune(history, limit) {
  var values = Array.isArray(history) ? history : []
  var max = limit === undefined || limit === null ? DEFAULT_LIMIT : Number(limit)
  if (isNaN(max) || max < 1) max = DEFAULT_LIMIT
  if (values.length <= max) return { entries: values, droppedImagePaths: [] }

  var kept = values.slice(0, max)
  var dropped = values.slice(max)
  var droppedImagePaths = []
  for (var i = 0; i < dropped.length; i++) {
    if (dropped[i] && dropped[i].type === "image" && dropped[i].path)
      droppedImagePaths.push(dropped[i].path)
  }
  // Keep pins even beyond the limit? No — pins are ordered to the top by
  // search instead; the store stays purely recency-ordered.
  return { entries: kept, droppedImagePaths: droppedImagePaths }
}

// Retention: drop entries older than maxAgeSeconds (-1 = keep forever).
// Pinned entries are exempt — pins are favorites; delete them explicitly.
// Returns { entries, droppedImagePaths } like prune().
function pruneByAge(history, maxAgeSeconds, now) {
  var values = Array.isArray(history) ? history : []
  if (maxAgeSeconds === undefined || maxAgeSeconds === null || maxAgeSeconds < 0)
    return { entries: values, droppedImagePaths: [] }
  var cutoff = now - maxAgeSeconds
  var kept = []
  var droppedImagePaths = []
  for (var i = 0; i < values.length; i++) {
    var e = values[i]
    if (!e) continue
    if ((Number(e.ts) || 0) < cutoff && !e.pinned) {
      if (e.type === "image" && e.path) droppedImagePaths.push(e.path)
      continue
    }
    kept.push(e)
  }
  return { entries: kept, droppedImagePaths: droppedImagePaths }
}

// Parse this plugin's settings from the shell.json contents. Every key is
// optional; unknown keys are ignored. Reads only the plugins[] entry whose
// id matches.
function parseSettings(raw, pluginId) {
  var out = { historyLimit: DEFAULT_LIMIT, maxAgeDays: 0, maxRows: 200, qrDecode: true }
  var config = null
  try { config = JSON.parse(String(raw || "{}")) } catch (e) { return out }
  if (!config || !Array.isArray(config.plugins)) return out
  for (var i = 0; i < config.plugins.length; i++) {
    var entry = config.plugins[i]
    if (!entry || entry.id !== pluginId) continue

    var n = Number(entry.historyLimit)
    if (isFinite(n) && n >= 1) out.historyLimit = Math.floor(n)

    n = Number(entry.maxAgeDays)
    if (isFinite(n) && n >= 0) out.maxAgeDays = Math.floor(n)

    n = Number(entry.maxRows)
    if (isFinite(n) && n >= 1) out.maxRows = Math.floor(n)

    if (typeof entry.qrDecode === "boolean") out.qrDecode = entry.qrDecode

    break
  }
  return out
}

// Build the search-row context Fuzzy.searchRows expects.
function buildRow(entry, derivedType, now) {
  var content = ""
  if (entry.type === "image") {
    content = fileLabel(entry.path) + " " + String(entry.mime || "")
    if (entry.qr) content += " " + String(entry.qr).slice(0, 500)
  } else if (entry.type === "files") {
    content = (entry.paths || []).join(" ")
  } else {
    // Cap haystack size for speed; deep content is still previewable.
    content = String(entry.text || "").slice(0, 4000)
  }
  return {
    entry: entry,
    content: content,
    app: String(entry.app || ""),
    type: derivedType,
    ts: Number(entry.ts) || 0,
    pinned: !!entry.pinned,
    uses: Number(entry.uses) || 0,
    bytes: Number(entry.bytes) || 0
  }
}

function fileLabel(p) {
  var s = String(p || "")
  var idx = s.lastIndexOf("/")
  return idx === -1 ? s : s.slice(idx + 1)
}
