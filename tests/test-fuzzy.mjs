import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLib } from "./harness.mjs"

const Fuzzy = loadLib("Fuzzy.js")

test("parseDuration", () => {
  assert.equal(Fuzzy.parseDuration("10m"), 600)
  assert.equal(Fuzzy.parseDuration("2h"), 7200)
  assert.equal(Fuzzy.parseDuration("3d"), 259200)
  assert.equal(Fuzzy.parseDuration("1w"), 604800)
  assert.equal(Fuzzy.parseDuration("45s"), 45)
  assert.ok(isNaN(Fuzzy.parseDuration("abc")))
  assert.ok(isNaN(Fuzzy.parseDuration("10")))
})

test("parseQuery basics", () => {
  const q = Fuzzy.parseQuery("type:image app:firefox today")
  assert.equal(q.type, "image")
  assert.equal(q.app, "firefox")
  assert.equal(q.maxAge, 86400)
  assert.equal(q.terms.length, 0)
})

test("parseQuery type prefixes and aliases", () => {
  assert.equal(Fuzzy.parseQuery("type:img").type, "image")
  assert.equal(Fuzzy.parseQuery("type:url").type, "link")
  assert.equal(Fuzzy.parseQuery("type:colour").type, "color")
  assert.equal(Fuzzy.parseQuery("type:js").type, "json")
})

test("parseQuery age comparisons", () => {
  const q = Fuzzy.parseQuery("<2h hello >30s")
  assert.equal(q.maxAge, 7200)
  assert.equal(q.minAge, 30)
  assert.equal(q.terms.length, 1); assert.equal(q.terms[0], "hello")
})

test("parseQuery pinned", () => {
  assert.equal(Fuzzy.parseQuery("pin").pinned, true)
  assert.equal(Fuzzy.parseQuery("is:pinned foo").pinned, true)
  assert.equal(Fuzzy.parseQuery("foo").pinned, false)
})

test("fuzzyMatch subsequence", () => {
  assert.ok(Fuzzy.fuzzyMatch("hlo", "hello world"))
  assert.equal(Fuzzy.fuzzyMatch("zzz", "hello world"), null)
  assert.ok(Fuzzy.fuzzyMatch("", ""))
  const m = Fuzzy.fuzzyMatch("", "anything")
  assert.equal(m.positions.length, 0)
})

test("fuzzyMatch scores prefix above scattered", () => {
  const prefix = Fuzzy.fuzzyMatch("fun", "function foo()")
  const scattered = Fuzzy.fuzzyMatch("fun", "a x f a u a n a")
  assert.ok(prefix.score > scattered.score)
})

test("fuzzyMatch consecutive beats gapped", () => {
  const consec = Fuzzy.fuzzyMatch("abc", "xxabcxx")
  const gapped = Fuzzy.fuzzyMatch("abc", "axbxc")
  assert.ok(consec.score > gapped.score)
})

test("fuzzyMatch prefers shorter haystack on substring ties", () => {
  const short = Fuzzy.fuzzyMatch("error", "error handling")
  const long = Fuzzy.fuzzyMatch("error", "an unexpected error occurred while processing the request payload")
  assert.ok(short.score > long.score)
})

test("searchRows empty query sorts by recency", () => {
  const now = 1000000
  const rows = [
    { entry: {}, content: "old", app: "", type: "text", ts: now - 500000, pinned: false, uses: 0, bytes: 3 },
    { entry: {}, content: "new", app: "", type: "text", ts: now - 10, pinned: false, uses: 0, bytes: 3 }
  ]
  const res = Fuzzy.searchRows(rows, "", now, 10)
  assert.equal(res.length, 2)
  assert.equal(res[0].row.content, "new")
})

test("searchRows fuzzy ranks match above recency when strong", () => {
  const now = 1000000
  const rows = [
    { entry: {}, content: "completely unrelated old entry", app: "", type: "text", ts: now, pinned: false, uses: 0, bytes: 5 },
    { entry: {}, content: "function makeAwesome() { return true }", app: "", type: "code", ts: now - 86400 * 30, pinned: false, uses: 0, bytes: 5 }
  ]
  const res = Fuzzy.searchRows(rows, "awesome", now, 10)
  assert.ok(res[0].row.content.toLowerCase().includes("awesome"))
})

test("searchRows type filter", () => {
  const now = 1000000
  const rows = [
    { entry: {}, content: "https://example.com", app: "", type: "link", ts: now, pinned: false, uses: 0, bytes: 3 },
    { entry: {}, content: "plain text", app: "", type: "text", ts: now, pinned: false, uses: 0, bytes: 3 }
  ]
  const res = Fuzzy.searchRows(rows, "type:link", now, 10)
  assert.equal(res.length, 1)
  assert.equal(res[0].row.type, "link")
})

test("searchRows multi-term AND", () => {
  const now = 1000000
  const rows = [
    { entry: {}, content: "deploy staging now", app: "", type: "text", ts: now, pinned: false, uses: 0, bytes: 3 },
    { entry: {}, content: "deploy production", app: "", type: "text", ts: now, pinned: false, uses: 0, bytes: 3 }
  ]
  const res = Fuzzy.searchRows(rows, "deploy staging", now, 10)
  assert.equal(res.length, 1)
  assert.equal(res[0].row.content, "deploy staging now")
})

test("searchRows matches app field", () => {
  const now = 1000000
  const rows = [
    { entry: {}, content: "some text", app: "firefox", type: "text", ts: now, pinned: false, uses: 0, bytes: 3 },
    { entry: {}, content: "other text", app: "ghostty", type: "text", ts: now, pinned: false, uses: 0, bytes: 3 }
  ]
  const res = Fuzzy.searchRows(rows, "fire", now, 10)
  assert.equal(res.length, 1)
  assert.equal(res[0].row.app, "firefox")
})

test("searchRows pinned boost wins", () => {
  const now = 1000000
  const rows = [
    { entry: { pinned: true }, content: "zzz pinned weak", app: "", type: "text", ts: now - 86400 * 10, pinned: true, uses: 0, bytes: 3 },
    { entry: {}, content: "fresh", app: "", type: "text", ts: now, pinned: false, uses: 0, bytes: 3 }
  ]
  const res = Fuzzy.searchRows(rows, "", now, 10)
  assert.equal(res[0].row.content, "zzz pinned weak")
})

test("searchRows respects limit", () => {
  const now = 1000000
  const rows = []
  for (let i = 0; i < 50; i++)
    rows.push({ entry: {}, content: "item " + i, app: "", type: "text", ts: now - i, pinned: false, uses: 0, bytes: 3 })
  const res = Fuzzy.searchRows(rows, "", now, 10)
  assert.equal(res.length, 10)
})

test("highlightFirstLine escapes and wraps", () => {
  const m = Fuzzy.fuzzyMatch("ab", "a <b> abc")
  const html = Fuzzy.highlightFirstLine("a <b> abc", m.positions, "<b>", "</b>")
  assert.ok(!html.includes("<b> <"))
  assert.ok(html.includes("&lt;b&gt;"))
  assert.ok(html.includes("<b>a</b>"))
})

test("highlightFirstLine multiline only first line", () => {
  const text = "alpha\nbeta\nalpha"
  const m = Fuzzy.fuzzyMatch("alpha", text)
  const html = Fuzzy.highlightFirstLine(text, m.positions, "<b>", "</b>")
  assert.ok(!html.includes("\n"))
})

test("parseQuery yesterday bounds", () => {
  const q = Fuzzy.parseQuery("yesterday")
  assert.equal(q.maxAge, 172800)
})
