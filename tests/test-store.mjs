import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLib } from "./harness.mjs"

const Store = loadLib("Store.js")

test("hash32 stable and hex", () => {
  assert.equal(Store.hash32("hello"), Store.hash32("hello"))
  assert.match(Store.hash32("hello"), /^[0-9a-f]{8}$/)
  assert.notEqual(Store.hash32("hello"), Store.hash32("hellp"))
})

test("normalize text", () => {
  const e = Store.normalize({ type: "text", text: " hi ", ts: 100, app: "ff", bytes: 4 })
  assert.equal(e.text, " hi ")
  assert.equal(e.ts, 100)
  assert.equal(e.uses, 0)
  assert.ok(e.id.startsWith("txt:"))
  assert.equal(Store.normalize({ type: "text", text: "   " }), null)
  assert.equal(Store.normalize({ type: "bogus" }), null)
})

test("normalize image and files", () => {
  const img = Store.normalize({ type: "image", path: "/x/a.png", mime: "image/png", w: 10, h: 20 })
  assert.equal(img.mime, "image/png")
  assert.equal(img.w, 10)
  assert.equal(Store.normalize({ type: "image", path: "" }), null)
  const files = Store.normalize({ type: "files", paths: ["/a", "", "/b"] })
  assert.equal(files.paths.length, 2); assert.equal(files.paths[0], "/a"); assert.equal(files.paths[1], "/b")
  assert.equal(Store.normalize({ type: "files", paths: [] }), null)
})

test("addEntry dedupes and bumps to front, keeps pin/uses", () => {
  let h = []
  h = Store.addEntry(h, { type: "text", text: "a", ts: 1 }, 10)
  h = Store.addEntry(h, { type: "text", text: "b", ts: 2 }, 10)
  assert.equal(h.length, 2)
  const a = Store.findById(h, h.find(e => e.text === "a").id)
  a.pinned = true
  a.uses = 3
  h = Store.addEntry(h, { type: "text", text: "a", ts: 5 }, 10)
  assert.equal(h.length, 2)
  assert.equal(h[0].text, "a")
  assert.equal(h[0].ts, 5)
  assert.equal(h[0].pinned, true)
  assert.equal(h[0].uses, 3)
})

test("addEntry keeps all entries; prune truncates", () => {
  let h = []
  for (let i = 0; i < 20; i++) h = Store.addEntry(h, { type: "text", text: "t" + i, ts: i })
  assert.equal(h.length, 20)
  const r = Store.prune(h, 5)
  assert.equal(r.entries.length, 5)
  assert.equal(r.entries[0].text, "t19")
})

test("regression: addEntry at limit must not leak evicted images (prune reports them)", () => {
  // Images beyond the limit are only reclaimable if prune() sees them,
  // which is why addEntry must not truncate by itself.
  let h = []
  for (let i = 0; i < 10; i++)
    h = Store.addEntry(h, { type: i < 2 ? "image" : "text", path: "/tmp/x" + i + ".png", text: "t" + i, ts: i })
  const r = Store.prune(h, 5)
  assert.ok(r.droppedImagePaths.includes("/tmp/x0.png"))
  assert.ok(r.droppedImagePaths.includes("/tmp/x1.png"))
})

test("removeById / findById / togglePin / touch", () => {
  let h = Store.addEntry([], { type: "text", text: "x", ts: 1 }, 10)
  const id = h[0].id
  assert.equal(Store.findById(h, id).text, "x")
  h = Store.togglePin(h, id)
  assert.equal(h[0].pinned, true)
  h = Store.togglePin(h, id)
  assert.equal(h[0].pinned, undefined)
  h = Store.touch(h, id, 999)
  assert.equal(h[0].uses, 1)
  assert.equal(h[0].ts, 999)
  h = Store.removeById(h, id)
  assert.equal(h.length, 0)
  assert.equal(Store.findById(h, id), null)
})

test("prune reports dropped images", () => {
  let h = []
  for (let i = 0; i < 10; i++)
    h.push({ id: "i" + i, type: i >= 6 ? "image" : "text", path: "/tmp/img" + i + ".png", text: "t" + i, ts: i, bytes: 1, app: "", uses: 0 })
  const r = Store.prune(h, 5)
  assert.equal(r.entries.length, 5)
  assert.equal(r.droppedImagePaths.length, 4)
  assert.deepEqual([...r.droppedImagePaths].join(","), ["/tmp/img6.png","/tmp/img7.png","/tmp/img8.png","/tmp/img9.png"].join(","))
})

test("parseHistory tolerates garbage", () => {
  assert.equal(Store.parseHistory("not json").length, 0)
  assert.equal(Store.parseHistory('{"a":1}').length, 0)
  assert.equal(Store.parseHistory("[]").length, 0)
  const h = Store.parseHistory('[{"type":"text","text":"ok"},{"type":"bogus"}]')
  assert.equal(h.length, 1)
})

test("buildRow caps content haystack", () => {
  const row = Store.buildRow({ type: "text", text: "x".repeat(9000), ts: 1, bytes: 9000, app: "a", uses: 0 }, "text", 1)
  assert.equal(row.content.length, 4000)
})

test("entryId distinct for distinct content", () => {
  const a = Store.entryId({ type: "text", text: "one" })
  const b = Store.entryId({ type: "text", text: "two" })
  assert.notEqual(a, b)
})

test("qr payload passes through normalize and dedup", () => {
  const e = Store.normalize({ type: "image", path: "/x/qr.png", mime: "image/png", w: 100, h: 100, qr: "https://example.com" })
  assert.equal(e.qr, "https://example.com")
  // Re-copy of the same image keeps the decoded QR even if the new capture lacks it.
  let h = Store.addEntry([], { type: "image", path: "/x/qr.png", qr: "https://example.com", ts: 1 })
  h = Store.addEntry(h, { type: "image", path: "/x/qr.png", ts: 2 })
  assert.equal(h.length, 1)
  assert.equal(h[0].qr, "https://example.com")
  assert.equal(h[0].ts, 2)
})

test("buildRow makes QR payload searchable", () => {
  const row = Store.buildRow({ type: "image", path: "/x/qr.png", mime: "image/png", qr: "secret-payload-xyz", ts: 1, bytes: 10, app: "", uses: 0 }, "image", 1)
  assert.ok(row.content.includes("secret-payload-xyz"))
})

test("pruneByAge drops old entries, keeps pins, reports images", () => {
  const now = 1000000
  const h = [
    { id: "new", type: "text", text: "fresh", ts: now - 10, bytes: 1, app: "", uses: 0 },
    { id: "old", type: "text", text: "old", ts: now - 100 * 86400, bytes: 1, app: "", uses: 0 },
    { id: "oldimg", type: "image", path: "/tmp/old.png", ts: now - 90 * 86400, bytes: 1, app: "", uses: 0 },
    { id: "oldpin", type: "text", text: "pinned old", ts: now - 200 * 86400, pinned: true, bytes: 1, app: "", uses: 0 }
  ]
  const r = Store.pruneByAge(h, 30 * 86400, now)
  assert.deepEqual(r.entries.map(e => e.id).sort().join(","), ["new", "oldpin"].sort().join(","))
  assert.equal(r.droppedImagePaths.length, 1)
})

test("pruneByAge no-op when forever", () => {
  const h = [{ id: "a", type: "text", text: "x", ts: 1, bytes: 1, app: "", uses: 0 }]
  const r = Store.pruneByAge(h, -1, 1000000)
  assert.equal(r.entries.length, 1)
  assert.equal(r.droppedImagePaths.length, 0)
})

test("parseSettings from shell.json", () => {
  const raw = JSON.stringify({
    plugins: [
      { id: "other.plugin" },
      { id: "tank.clipboard", historyLimit: 500, maxAgeDays: 14, maxRows: 50, qrDecode: false, customKey: 1 }
    ]
  })
  const s = Store.parseSettings(raw, "tank.clipboard")
  assert.equal(s.historyLimit, 500)
  assert.equal(s.maxAgeDays, 14)
  assert.equal(s.maxRows, 50)
  assert.equal(s.qrDecode, false)
  const d = Store.parseSettings("{}", "tank.clipboard")
  assert.equal(d.historyLimit, 1500)
  assert.equal(d.maxAgeDays, 0)
  assert.equal(d.maxRows, 200)
  assert.equal(d.qrDecode, true)
})

test("parseSettings ignores garbage", () => {
  const s = Store.parseSettings("not json", "tank.clipboard")
  assert.equal(s.historyLimit, 1500)
})

test("ocr passes through normalize, dedup, and search", () => {
  const e = Store.normalize({ type: "image", path: "/x/s.png", mime: "image/png", ocr: "deploy staging" })
  assert.equal(e.ocr, "deploy staging")
  let h = Store.addEntry([], { type: "image", path: "/x/s.png", ocr: "deploy staging", ts: 1 })
  h = Store.addEntry(h, { type: "image", path: "/x/s.png", ts: 2 })
  assert.equal(h[0].ocr, "deploy staging")
  const row = Store.buildRow(h[0], "image", 2)
  assert.ok(row.content.includes("deploy staging"))
})

test("parseSettings ocr keys", () => {
  const raw = JSON.stringify({ plugins: [{ id: "tank.clipboard", ocr: false, ocrLang: "deu" }] })
  const s = Store.parseSettings(raw, "tank.clipboard")
  assert.equal(s.ocr, false)
  assert.equal(s.ocrLang, "deu")
})
