.pragma library

// Fuzzy search engine for the clipboard picker.
//
// Pure ES5, no imports, so the same file runs inside QML (.pragma library)
// and under node (tests load it with the `vm` module).
//
// Query language (whitespace separated tokens):
//   plain words          fuzzy subsequence match against content + app + type
//   type:<prefix>        filter by derived type (image, link, color, code, json,
//                        file, email, html, number, text) — prefix match
//   app:<word>           fuzzy match against the source app
//   is:pinned  pin       only pinned entries
//   today  yesterday     age filters
//   week  month          age filters
//   <10m  >2h  <3d       age comparisons (s/m/h/d/w suffixes)
//
// Rows handed to searchRows() are precomputed by the caller:
//   { entry, content, app, type, ts, pinned, uses, bytes }

// ---------------------------------------------------------------- durations

var DURATION_UNITS = { s: 1, m: 60, h: 3600, d: 86400, w: 604800 }

function parseDuration(str) {
  var m = /^(\d+(?:\.\d+)?)\s*([smhdw])$/.exec(String(str || "").trim().toLowerCase())
  if (!m) return NaN
  var unit = DURATION_UNITS[m[2]]
  return Number(m[1]) * unit
}

var AGE_WORDS = {
  today: 86400,
  yesterday: 172800,
  week: 604800,
  month: 2592000,
  year: 31536000
}

var TYPE_ALIASES = {
  image: "image", img: "image", pic: "image", photo: "image", screenshot: "image",
  link: "link", url: "link", links: "link", urls: "link",
  color: "color", colour: "color", hex: "color",
  code: "code", snippet: "code",
  json: "json",
  file: "files", files: "files", folder: "files", path: "files", dir: "files",
  email: "email", mail: "email",
  html: "html",
  number: "number", num: "number",
  text: "text", txt: "text"
}

// ---------------------------------------------------------------- query

function parseQuery(q) {
  var out = { terms: [], type: "", app: "", pinned: false, minAge: -1, maxAge: -1 }
  var raw = String(q || "").split(/\s+/)
  for (var i = 0; i < raw.length; i++) {
    var tok = raw[i]
    if (!tok) continue
    var lower = tok.toLowerCase()

    if (lower.indexOf("type:") === 0 && tok.length > 5) {
      var wanted = lower.slice(5)
      var canonical = TYPE_ALIASES[wanted]
      if (canonical) { out.type = canonical; continue }
      // prefix match: "type:im" → image
      var matchedType = ""
      for (var key in TYPE_ALIASES) {
        if (key.indexOf(wanted) === 0) { matchedType = TYPE_ALIASES[key]; break }
      }
      if (matchedType) { out.type = matchedType; continue }
      // unknown type — treat the whole token as a term
      out.terms.push(tok)
      continue
    }

    if (lower.indexOf("app:") === 0 && tok.length > 4) {
      out.app = tok.slice(4).toLowerCase()
      continue
    }

    if (lower === "is:pinned" || lower === "pinned" || lower === "pin") {
      out.pinned = true
      continue
    }

    if (lower === "is:text" || lower === "star" || lower === "fav") {
      out.terms.push(tok)
      continue
    }

    if (AGE_WORDS[lower] !== undefined) {
      out.maxAge = AGE_WORDS[lower]
      if (lower === "yesterday") out.minAge = 86400
      continue
    }

    if ((lower.charAt(0) === "<" || lower.charAt(0) === ">") && lower.length > 1) {
      var dur = parseDuration(lower.slice(1))
      if (!isNaN(dur)) {
        if (lower.charAt(0) === "<") out.maxAge = dur
        else out.minAge = dur
        continue
      }
    }

    out.terms.push(tok)
  }
  return out
}

// ---------------------------------------------------------------- fuzzy match

// Greedy case-insensitive subsequence match with fzf-style bonuses.
// Returns null when `needle` is not a subsequence of `haystack`, otherwise
// { score, positions } where positions are indices into the raw haystack.
function fuzzyMatch(needle, haystack) {
  if (!needle) return { score: 0, positions: [] }
  if (!haystack) return null
  var nl = needle.toLowerCase()
  var hl = haystack.toLowerCase()
  var n = nl.length
  var h = hl.length
  if (n > h) return null

  // Fast reject: all characters must be present in order via greedy scan.
  var positions = new Array(n)
  var j = 0
  for (var i = 0; i < h && j < n; i++) {
    if (hl.charCodeAt(i) === nl.charCodeAt(j)) positions[j++] = i
  }
  if (j < n) return null

  // Exact substring bonus (case-insensitive).
  var substringIdx = hl.indexOf(nl)
  var score = 0
  var consecutive = 0
  var prev = -2
  for (var k = 0; k < n; k++) {
    var pos = positions[k]
    if (pos === prev + 1) consecutive++
    else consecutive = 0
    score += 4 + consecutive * 3

    // Word boundary bonus: start of string or after a non-alphanumeric.
    if (pos === 0) score += 10
    else {
      var prevChar = hl.charCodeAt(pos - 1)
      if (!(prevChar >= 97 && prevChar <= 122) &&
          !(prevChar >= 48 && prevChar <= 57) &&
          !(prevChar >= 65 && prevChar <= 90))
        score += 8
    }

    // Gap penalty (light — we rank mostly by bonuses and recency).
    if (k > 0) {
      var gap = pos - positions[k - 1] - 1
      if (gap > 0) score -= Math.min(6, gap)
    }
    prev = pos
  }

  if (substringIdx >= 0) {
    var bonus = 40
    if (substringIdx === 0) bonus += 25
    // Prefer matches in shorter haystacks.
    bonus -= Math.min(20, hl.length / 200)
    if (bonus > score) {
      score = bonus
      for (var c = 0; c < n; c++) positions[c] = substringIdx + c
    }
  }

  // Length penalty so "func" ranks higher in short snippets than in essays.
  score -= Math.min(25, hl.length / 400)

  return { score: score, positions: positions }
}

var FIELDS = [
  { name: "content", weight: 1.0 },
  { name: "app", weight: 0.7 },
  { name: "type", weight: 0.6 }
]

// Every term must match in at least one field; the score is the sum of each
// term's best field score (already weighted). Positions returned are for the
// best-scoring content-field match (for highlighting).
function matchRow(queryTerms, row) {
  var total = 0
  var contentPositions = null
  for (var t = 0; t < queryTerms.length; t++) {
    var term = queryTerms[t]
    var best = -1
    for (var f = 0; f < FIELDS.length; f++) {
      var field = FIELDS[f]
      var text = field.name === "content" ? row.content
        : field.name === "app" ? row.app
        : row.type
      if (!text) continue
      var m = fuzzyMatch(term, text)
      if (m) {
        var weighted = m.score * field.weight
        if (weighted > best) {
          best = weighted
          if (field.name === "content") contentPositions = m.positions
        }
      }
    }
    if (best < 0) return null
    total += best
  }
  return { score: total, positions: contentPositions }
}

function ageFilterOk(parsed, ageSeconds) {
  if (parsed.maxAge >= 0 && ageSeconds > parsed.maxAge) return false
  if (parsed.minAge >= 0 && ageSeconds < parsed.minAge) return false
  return true
}

function recencyBonus(ts, now) {
  if (!ts) return 0
  var ageDays = Math.max(0, (now - ts) / 86400)
  return 120 / (1 + ageDays)
}

// rows: [{ entry, content, app, type, ts, pinned, uses, bytes }]
// Returns up to `limit` rows sorted by relevance: [{ row, score, positions, type }]
function searchRows(rows, queryStr, now, limit) {
  var parsed = parseQuery(queryStr)
  var results = []
  if (parsed.maxAge < 0 && parsed.terms.length === 0 && !parsed.type && !parsed.app && !parsed.pinned)
    parsed.maxAge = -1 // no-op, keeps empty-query path below cheap

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i]

    if (parsed.type && row.type !== parsed.type) continue
    if (parsed.pinned && !row.entry.pinned) continue

    var age = row.ts > 0 ? Math.max(0, now - row.ts) : 0
    if (parsed.maxAge >= 0 && age > parsed.maxAge) continue
    if (parsed.minAge >= 0 && age < parsed.minAge) continue

    if (parsed.app) {
      var appMatch = fuzzyMatch(parsed.app, row.app || "")
      if (!appMatch) continue
    }

    var matched = null
    if (parsed.terms.length > 0) {
      matched = matchRow(parsed.terms, row)
      if (!matched) continue
    }

    var score = matched ? matched.score : 0
    score += recencyBonus(row.ts, now)
    if (row.entry.pinned) score += 500
    if (row.uses > 0) score += 4 * Math.min(10, row.uses)

    results.push({
      row: row,
      score: score,
      positions: matched ? matched.positions : null
    })
  }

  results.sort(function(a, b) {
    if (b.score !== a.score) return b.score - a.score
    return (b.row.ts || 0) - (a.row.ts || 0)
  })

  var cap = limit === undefined ? 200 : limit
  if (results.length > cap) results.length = cap
  return results
}

// Escape for QML StyledText (HTML-ish).
function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

// Build highlight markup for the first line of `text` given match positions.
// positions are indices into the RAW text; text is escaped segment-by-segment.
function highlightFirstLine(text, positions, openTag, closeTag) {
  text = String(text || "")
  var firstLineEnd = text.indexOf("\n")
  var line = firstLineEnd === -1 ? text : text.slice(0, firstLineEnd)
  if (!positions || positions.length === 0 || !line)
    return escapeHtml(line)

  var inLine = []
  for (var i = 0; i < positions.length; i++) {
    if (positions[i] < line.length) inLine.push(positions[i])
  }
  if (inLine.length === 0) return escapeHtml(line)

  var out = ""
  var prev = 0
  for (var p = 0; p < inLine.length; p++) {
    var idx = inLine[p]
    if (idx < prev) continue // match spans past the line break — skip tail
    out += escapeHtml(line.slice(prev, idx))
    out += openTag + escapeHtml(line.charAt(idx)) + closeTag
    prev = idx + 1
  }
  out += escapeHtml(line.slice(prev))
  return out
}
