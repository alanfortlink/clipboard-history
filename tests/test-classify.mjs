import { test } from "node:test"
import assert from "node:assert/strict"
import { loadLib } from "./harness.mjs"

const Classify = loadLib("Classify.js")

test("deriveType image/files pass through", () => {
  assert.equal(Classify.deriveType({ type: "image", path: "/tmp/a.png" }), "image")
  assert.equal(Classify.deriveType({ type: "files", paths: ["/tmp/a"] }), "files")
})

test("deriveType colors", () => {
  assert.equal(Classify.deriveType({ type: "text", text: "#ff0000" }), "color")
  assert.equal(Classify.deriveType({ type: "text", text: "#f00" }), "color")
  assert.equal(Classify.deriveType({ type: "text", text: "#ff0000cc" }), "color")
  assert.equal(Classify.deriveType({ type: "text", text: "rgb(12, 34, 56)" }), "color")
  assert.equal(Classify.deriveType({ type: "text", text: "rgba(1,2,3,0.5)" }), "color")
  assert.equal(Classify.deriveType({ type: "text", text: "hsl(120, 50%, 50%)" }), "color")
  assert.equal(Classify.deriveType({ type: "text", text: "#gggggg" }), "text")
})

test("deriveType link / email / number", () => {
  assert.equal(Classify.deriveType({ type: "text", text: "https://example.com/x?y=1" }), "link")
  assert.equal(Classify.deriveType({ type: "text", text: "www.example.com" }), "link")
  assert.equal(Classify.deriveType({ type: "text", text: "example.com" }), "link")
  assert.equal(Classify.deriveType({ type: "text", text: "foo@bar.io" }), "email")
  assert.equal(Classify.deriveType({ type: "text", text: "42" }), "number")
  assert.equal(Classify.deriveType({ type: "text", text: "-3.14" }), "number")
  assert.equal(Classify.deriveType({ type: "text", text: "1,234,567" }), "number")
})

test("deriveType json / code / html", () => {
  assert.equal(Classify.deriveType({ type: "text", text: '{"a": [1, 2, 3]}' }), "json")
  assert.equal(Classify.deriveType({ type: "text", text: "[1, 2, 3]" }), "json")
  assert.equal(Classify.deriveType({ type: "text", text: "<html><body>hi</body></html>" }), "html")
  assert.equal(Classify.deriveType({ type: "text", text: "<div class=\"x\">y</div>" }), "html")
  const code = "def main():\n    return print('hello world')\n\nif __name__ == '__main__':\n    main()"
  assert.equal(Classify.deriveType({ type: "text", text: code }), "code")
  assert.equal(Classify.deriveType({ type: "text", text: "just a normal sentence, nothing special" }), "text")
})

test("prettyJson", () => {
  assert.equal(Classify.prettyJson('{"a":1}'), '{\n  "a": 1\n}')
  assert.equal(Classify.prettyJson("not json"), "")
  assert.equal(Classify.prettyJson('{"a":1}', 3), "")
})

test("stripHtml", () => {
  assert.equal(Classify.stripHtml("<p>Hello &amp; <b>world</b></p>"), "Hello & world")
  assert.equal(Classify.stripHtml("<style>x{}</style><p>hi</p>"), "hi")
})

test("urlDomain", () => {
  assert.equal(Classify.urlDomain("https://www.example.com/a/b"), "example.com")
  assert.equal(Classify.urlDomain("example.com:8080/x"), "example.com:8080")
})

test("prettyApp", () => {
  assert.equal(Classify.prettyApp("com.mitchellh.ghostty"), "Ghostty")
  assert.equal(Classify.prettyApp("firefox"), "Firefox")
  assert.equal(Classify.prettyApp("Code"), "VS Code")
  assert.equal(Classify.prettyApp("org.gnome.Nautilus"), "Files")
  assert.equal(Classify.prettyApp("someapp-2.1.0"), "Someapp")
  assert.equal(Classify.prettyApp(""), "")
})

test("formatBytes", () => {
  assert.equal(Classify.formatBytes(512), "512 B")
  assert.equal(Classify.formatBytes(2048), "2.0 KB")
  assert.equal(Classify.formatBytes(1048576), "1.0 MB")
  assert.equal(Classify.formatBytes(NaN), "")
})

test("formatAge", () => {
  const now = 1000000000
  assert.equal(Classify.formatAge(now - 10, now), "just now")
  assert.equal(Classify.formatAge(now - 120, now), "2m ago")
  assert.equal(Classify.formatAge(now - 7200, now), "2h ago")
  assert.equal(Classify.formatAge(now - 86400 * 2, now), "2d ago")
  assert.ok(Classify.formatAge(now - 86400 * 30, now).length > 0)
})

test("textStats", () => {
  const s = Classify.textStats("one two three\nfour")
  assert.equal(s.words, 4)
  assert.equal(s.lines, 2)
  assert.equal(s.chars, 18)
})

test("typeIcon/label cover all types", () => {
  for (const t of ["image", "files", "color", "link", "email", "json", "code", "html", "number", "text"]) {
    assert.ok(Classify.typeIcon(t).length > 0, t)
    assert.ok(Classify.typeLabel(t).length > 0, t)
  }
})

test("colorToRgb hex forms", () => {
  assert.deepEqual([...Classify.colorToRgb("#ff0000")], [255, 0, 0])
  assert.deepEqual([...Classify.colorToRgb("#f00")], [255, 0, 0])
  assert.deepEqual([...Classify.colorToRgb("#ff0000cc")], [255, 0, 0])
  assert.deepEqual([...Classify.colorToRgb("rgb(12, 34, 56)")], [12, 34, 56])
})

test("colorToHsl conversions", () => {
  const hsl = Classify.colorToHsl("#ff0000")
  assert.deepEqual([...hsl], [0, 100, 50])
  const rgb = Classify.colorToRgb("hsl(120, 100%, 50%)")
  assert.deepEqual([...rgb], [0, 255, 0])
  const back = Classify.rgbToHsl(...Classify.hslToRgb(240, 100, 50))
  assert.deepEqual([...back], [240, 100, 50])
})

test("colorToRgb rejects junk", () => {
  assert.equal(Classify.colorToRgb("#gg"), null)
  assert.equal(Classify.colorToRgb("hello"), null)
})

test("extractUrl finds links in text and QR payloads", () => {
  assert.equal(Classify.extractUrl("see https://omarchy.org/docs?a=1 for details."), "https://omarchy.org/docs?a=1")
  assert.equal(Classify.extractUrl("go to www.example.com now"), "www.example.com")
  assert.equal(Classify.extractUrl("https://x.io"), "https://x.io")
  assert.equal(Classify.extractUrl("no link here"), "")
  assert.equal(Classify.extractUrl(""), "")
  // trailing punctuation is not part of the URL
  assert.equal(Classify.extractUrl("(https://a.io/x)."), "https://a.io/x")
})
