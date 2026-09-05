// Test harness: loads .pragma library files (plain ES5, no imports) into a
// fresh vm context so the same files work in QML and under node.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import path from "node:path"
import vm from "node:vm"

const testsDir = path.dirname(fileURLToPath(import.meta.url))
const pluginDir = path.join(testsDir, "..")

export function loadLib(name) {
  let src = readFileSync(path.join(pluginDir, name), "utf8")
  // QML's ".pragma library" directive is not valid JS outside QML.
  src = src.replace(/^\.pragma\s+library\s*$/m, "")
  const sandbox = {}
  vm.createContext(sandbox)
  vm.runInContext(src, sandbox)
  return sandbox
}

export const here = pluginDir
