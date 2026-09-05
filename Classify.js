.pragma library

// Entry classification and formatting helpers.
// Pure ES5, no imports — runs in QML (.pragma library) and node (tests).

// ---------------------------------------------------------------- types

var TYPES = {
  image:  { icon: "󰋲", label: "Image" },
  files:  { icon: "󰉋", label: "Files" },
  color:  { icon: "󰏘", label: "Color" },
  link:   { icon: "󰌹", label: "Link" },
  email:  { icon: "󰇮", label: "Email" },
  json:   { icon: "󰘦", label: "JSON" },
  code:   { icon: "󰅴", label: "Code" },
  html:   { icon: "󰩟", label: "HTML" },
  number: { icon: "󰎠", label: "Number" },
  text:   { icon: "󰈙", label: "Text" }
}

function typeIcon(t) { var e = TYPES[t]; return e ? e.icon : TYPES.text.icon }
function typeLabel(t) { var e = TYPES[t]; return e ? e.label : "Text" }

// Derived display type for a stored entry.
// entry: { type: "text"|"image"|"files", text?, path?, paths? }
function deriveType(entry) {
  if (!entry) return "text"
  if (entry.type === "image") return "image"
  if (entry.type === "files") return "files"
  var text = String(entry.text || "")
  if (!text) return "text"
  var trimmed = text.trim()
  if (!trimmed) return "text"

  if (trimmed.indexOf("\n") === -1) {
    if (isColor(trimmed)) return "color"
    if (isEmail(trimmed)) return "email"
    if (isUrl(trimmed)) return "link"
    if (isNumber(trimmed)) return "number"
  }

  if (trimmed.charAt(0) === "<" &&
      /<\/?[a-z][a-z0-9-]*(\s[^>]*)?>/i.test(trimmed.slice(0, 200)))
    return "html"

  if (isJson(trimmed)) return "json"
  if (looksLikeCode(trimmed)) return "code"
  return "text"
}

var COLOR_RE = /^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i
var RGB_RE = /^rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(?:,\s*(?:0|1|0?\.\d+)\s*)?\)$/i
var HSL_RE = /^hsla?\(\s*\d{1,3}\s*,\s*\d{1,3}%\s*,\s*\d{1,3}%\s*(?:,\s*(?:0|1|0?\.\d+)\s*)?\)$/i

function isColor(s) {
  return COLOR_RE.test(s) || RGB_RE.test(s) || HSL_RE.test(s)
}

function clampByte(n) { return Math.max(0, Math.min(255, Math.round(n))) }

// "#rgb"/"#rgba"/"#rrggbb"/"#rrggbbaa"/"rgb()"/"hsl()" → [r, g, b] or null.
function colorToRgb(s) {
  s = String(s || "").trim()
  var m = /^#([0-9a-f]+)$/i.exec(s)
  if (m) {
    var hex = m[1]
    if (hex.length === 3 || hex.length === 4) {
      return [
        parseInt(hex.charAt(0) + hex.charAt(0), 16),
        parseInt(hex.charAt(1) + hex.charAt(1), 16),
        parseInt(hex.charAt(2) + hex.charAt(2), 16)
      ]
    }
    if (hex.length === 6 || hex.length === 8) {
      return [
        parseInt(hex.slice(0, 2), 16),
        parseInt(hex.slice(2, 4), 16),
        parseInt(hex.slice(4, 6), 16)
      ]
    }
    return null
  }
  m = /^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})/i.exec(s)
  if (m) return [clampByte(Number(m[1])), clampByte(Number(m[2])), clampByte(Number(m[3]))]
  if (!HSL_RE.test(s)) return null
  var hsl = colorToHsl(s)
  if (!hsl) return null
  return hslToRgb(hsl[0], hsl[1], hsl[2])
}

function colorToHsl(s) {
  s = String(s || "").trim()
  var m = /^hsla?\(\s*(\d{1,3})\s*,\s*(\d{1,3})%\s*,\s*(\d{1,3})%/i.exec(s)
  if (m) return [Number(m[1]), Number(m[2]), Number(m[3])]
  var rgb = colorToRgb(s)
  if (!rgb) return null
  return rgbToHsl(rgb[0], rgb[1], rgb[2])
}

function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var h = 0, s = 0
  var l = (max + min) / 2
  if (max !== min) {
    var d = max - min
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
    if (max === r) h = ((g - b) / d + (g < b ? 6 : 0))
    else if (max === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h = Math.round(h * 60)
  }
  return [h, Math.round(s * 100), Math.round(l * 100)]
}

function hslToRgb(h, s, l) {
  s /= 100; l /= 100
  var c = (1 - Math.abs(2 * l - 1)) * s
  var x = c * (1 - Math.abs(((h / 60) % 2) - 1))
  var m = l - c / 2
  var rgb
  if (h < 60) rgb = [c, x, 0]
  else if (h < 120) rgb = [x, c, 0]
  else if (h < 180) rgb = [0, c, x]
  else if (h < 240) rgb = [0, x, c]
  else if (h < 300) rgb = [x, 0, c]
  else rgb = [c, 0, x]
  return [clampByte((rgb[0] + m) * 255), clampByte((rgb[1] + m) * 255), clampByte((rgb[2] + m) * 255)]
}

var URL_RE = /^(?:https?:\/\/|www\.)[^\s]+$/i
var BARE_DOMAIN_RE = /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}(?:\/[^\s]*)?$/i

function isUrl(s) {
  return URL_RE.test(s) || BARE_DOMAIN_RE.test(s)
}

var EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/

function isEmail(s) { return EMAIL_RE.test(s) }

var NUMBER_RE = /^[+-]?(?:\d{1,3}(?:,\d{3})*|\d+)(?:\.\d+)?%?$/

function isNumber(s) { return NUMBER_RE.test(s) }

function isJson(s) {
  var c = s.charAt(0)
  if (c !== "{" && c !== "[" && c !== '"') return false
  try {
    JSON.parse(s)
    return true
  } catch (e) {
    return false
  }
}

// Pretty-print JSON; returns "" when not parseable or too large.
function prettyJson(text, maxLen) {
  var cap = maxLen === undefined ? 65536 : maxLen
  if (!text || text.length > cap) return ""
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch (e) {
    return ""
  }
}

var CODE_HINTS = [
  /(?:^|\n)\s*(?:def |class |function |fn |func |const |let |var |import |from |package |using |#include)/,
  /(?:=>|->|::|&&|\|\||===|!==|:=)/,
  /(?:^|\n)\s*(?:if|for|while|switch|try|elif|elsif)\s*[(\s{]/,
  /;\s*$/,
  /^\s*#!/m,
  /<\/?[a-z][^>]*>/ // xml-ish (checked after html derive, fine for code view)
]

function looksLikeCode(s) {
  if (s.length > 100000) return false
  // Needs at least a little structure; single prose words are never code.
  var hints = 0
  for (var i = 0; i < CODE_HINTS.length; i++) {
    if (CODE_HINTS[i].test(s)) hints++
    if (hints >= 2) return true
  }
  // Many lines with consistent indentation / trailing semicolons.
  var lines = s.split("\n")
  if (lines.length >= 3) {
    var indented = 0
    for (var l = 0; l < lines.length; l++) {
      if (/^[ \t]+\S/.test(lines[l]) || /;\s*$/.test(lines[l])) indented++
    }
    if (indented / lines.length > 0.5) return true
  }
  return false
}

function stripHtml(s) {
  return String(s || "")
    .replace(/<(?:script|style)\b[^>]*>[\s\S]*?<\/(?:script|style)>/gi, "")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim()
}

function urlDomain(url) {
  var m = /^(?:https?:\/\/)?(?:www\.)?([^\/\s]+)/i.exec(String(url || "").trim())
  return m ? m[1] : ""
}

// First URL inside arbitrary text ("visit https://x.io/a for more", QR
// payloads, …). Returns "" when none. Bare domains are NOT extracted here —
// too noisy for prose; the shell-side open script has its own fallback.
function extractUrl(text) {
  var m = /https?:\/\/[^\s\]"'<>]+/i.exec(String(text || ""))
  if (m) return m[0].replace(/[.,;:)!]+$/, "")
  m = /(?:^|\s)(www\.[^\s\]"<>]+)/i.exec(String(text || ""))
  return m ? m[1].replace(/[.,;:)!]+$/, "") : ""
}

// ---------------------------------------------------------------- apps

var APP_NAMES = {
  ghostty: "Ghostty", "com.mitchellh.ghostty": "Ghostty", foot: "Foot",
  alacritty: "Alacritty", kitty: "kitty", wezterm: "WezTerm",
  "org.wezfurlong.wezterm": "WezTerm", code: "VS Code", "code-oss": "VS Code",
  Code: "VS Code", firefox: "Firefox", chromium: "Chromium",
  "Google-chrome": "Chrome", "google-chrome": "Chrome", brave: "Brave",
  "brave-browser": "Brave", slack: "Slack", discord: "Discord",
  obsidian: "Obsidian", spotify: "Spotify", telegram: "Telegram",
  "org.telegram.desktop": "Telegram", nautilus: "Files",
  "org.gnome.Nautilus": "Files", thunar: "Thunar", dolphin: "Dolphin",
  "org.kde.dolphin": "Dolphin", nvim: "Neovim", neovide: "Neovide",
  emacs: "Emacs", "jetbrains-idea": "IntelliJ IDEA", zed: "Zed", dev: "Dev",
  wps: "WPS", gimp: "GIMP", inkscape: "Inkscape", blender: "Blender",
  thunderbird: "Thunderbird", keepassxc: "KeePassXC", steam: "Steam"
}

function prettyApp(cls) {
  var s = String(cls || "").trim()
  if (!s) return ""
  if (APP_NAMES[s]) return APP_NAMES[s]
  // Strip reverse-DNS prefixes and version suffixes: com.foo.Bar-2.1 → Bar
  var noDns = s.replace(/^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_-]*)+\./i, "")
  noDns = noDns.replace(/[-_.]\d.*$/, "")
  if (!noDns) return s
  return noDns.charAt(0).toUpperCase() + noDns.slice(1)
}

// ---------------------------------------------------------------- formatting

function formatBytes(n) {
  n = Number(n)
  if (!isFinite(n) || n < 0) return ""
  if (n < 1024) return n + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB"
  return (n / (1024 * 1024)).toFixed(1) + " MB"
}

function formatAge(ts, now) {
  ts = Number(ts)
  if (!isFinite(ts) || ts <= 0) return ""
  var s = Math.max(0, Math.floor((now - ts)))
  if (s < 45) return "just now"
  if (s < 3600) return Math.floor(s / 60) + "m ago"
  if (s < 86400) {
    var h = Math.floor(s / 3600)
    return h + "h ago"
  }
  var d = Math.floor(s / 86400)
  if (d < 7) return d + "d ago"
  return formatDate(ts)
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function pad2(n) { return n < 10 ? "0" + n : "" + n }

function formatDate(ts) {
  ts = Number(ts)
  if (!isFinite(ts) || ts <= 0) return ""
  var d = new Date(ts * 1000)
  return MONTHS[d.getMonth()] + " " + d.getDate() + ", " +
    pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

function formatFullDate(ts) {
  ts = Number(ts)
  if (!isFinite(ts) || ts <= 0) return ""
  var d = new Date(ts * 1000)
  return MONTHS[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear() +
    " at " + pad2(d.getHours()) + ":" + pad2(d.getMinutes()) + ":" + pad2(d.getSeconds())
}

function plural(n, word) {
  return n === 1 ? "1 " + word : n + " " + word + "s"
}

function textStats(text) {
  var s = String(text || "")
  var words = 0
  var m = s.match(/\S+/g)
  if (m) words = m.length
  return {
    chars: s.length,
    words: words,
    lines: s === "" ? 0 : s.split("\n").length
  }
}

function firstLine(text, max) {
  var s = String(text || "")
  var nl = s.indexOf("\n")
  var line = nl === -1 ? s : s.slice(0, nl)
  if (max && line.length > max) return line.slice(0, max) + "…"
  return line
}

function fileBase(p) {
  var s = String(p || "").replace(/\/+$/, "")
  var idx = s.lastIndexOf("/")
  return idx === -1 ? s : s.slice(idx + 1)
}

function fileDir(p) {
  var s = String(p || "")
  var idx = s.lastIndexOf("/")
  if (idx <= 0) return idx === 0 ? "/" : ""
  return s.slice(0, idx)
}
