import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'

const lock = JSON.parse(readFileSync('package-lock.json', 'utf8'))
const selected = new Set()
function include(name, optional = false) {
  const key = `node_modules/${name}`
  if (selected.has(key)) return
  const entry = lock.packages[key]
  if (!entry) {
    if (optional) return
    throw new Error(`Missing locked dependency: ${name}`)
  }
  if (!entry.integrity || !entry.resolved) throw new Error(`Unsealed package: ${name}`)
  selected.add(key)
  for (const dependency of Object.keys(entry.dependencies ?? {})) include(dependency)
  for (const dependency of Object.keys(entry.optionalDependencies ?? {})) include(dependency, true)
}
include('tsx')
const manifest = {
  name: 'synapse-bwrap-private-diagnostic',
  version: '1.0.0',
  private: true,
  dependencies: { tsx: lock.packages['node_modules/tsx'].version },
}
const packages = { '': manifest }
for (const key of [...selected].sort()) packages[key] = lock.packages[key]
mkdirSync('probe-deps', { recursive: true })
writeFileSync('probe-deps/package.json', `${JSON.stringify(manifest, null, 2)}\n`)
writeFileSync('probe-deps/package-lock.json', `${JSON.stringify({
  name: manifest.name, version: manifest.version, lockfileVersion: 3,
  requires: true, packages,
}, null, 2)}\n`)
console.log(JSON.stringify([...selected].map(key => ({ package: key, version: packages[key].version }))))
