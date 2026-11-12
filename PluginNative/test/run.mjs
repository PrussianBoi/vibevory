// Runs the built runtime the way Swift does (a fresh global with __native), against disk plugins,
// with a fake REST backend, and prints each page's tree.  node test/run.mjs [pluginDir] [fixtures.json]
import fs from 'node:fs'
import vm from 'node:vm'
import path from 'node:path'

const dir = process.argv[2] || path.join(process.env.HOME, '.hermes/desktop-plugins')
const fixtures = process.argv[3] ? JSON.parse(fs.readFileSync(process.argv[3], 'utf8')) : {}
const out = {}
const ctx = { Promise, JSON, Math, Date, Object, Array, String, Number, Boolean, Error, Map, Set, WeakMap, WeakSet, Symbol, RegExp, Proxy, Reflect, encodeURIComponent, decodeURIComponent, parseInt, parseFloat, isNaN, Function }
const timers = new Map()
ctx.__native = {
  send(type, json) {
    const v = JSON.parse(json)
    if (type === 'render') out[v.root] = v.tree
    else if (type === 'log') console.log('  [js]', v.level, v.text.slice(0, 300))
    else if (type !== 'contributions') console.log('  [send]', type, json.slice(0, 200))
  },
  call(type, json, id) {
    const req = JSON.parse(json)
    setTimeout(() => {
      let res
      if (type === 'api') {
        const key = Object.keys(fixtures).find(k => req.path.startsWith(k))
        res = key ? { status: 200, body: JSON.stringify(fixtures[key]) } : { status: 404, body: '{"detail":"Not Found"}' }
      } else res = { error: 'no ' + type }
      ctx.__vibe.resolve(id, true, JSON.stringify(res))
    }, 5)
  },
  setTimer(id, ms, repeat) { timers.set(id, (repeat ? setInterval : setTimeout)(() => ctx.__vibe.fire(id), Math.min(ms, 50))) },
  clearTimer(id) { clearTimeout(timers.get(id)); clearInterval(timers.get(id)); timers.delete(id) },
  storageGet: () => null,
  storageSet: () => {}
}
vm.createContext(ctx)
vm.runInContext(fs.readFileSync(new URL('../../VoryMac/Plugins/plugin-runtime.js', import.meta.url), 'utf8'), ctx)
ctx.__vibe.start({ profile: 'default', gateway: 'open' })
for (const id of fs.readdirSync(dir).sort()) {
  const f = path.join(dir, id, 'plugin.js')
  if (!fs.existsSync(f)) continue
  const r = ctx.__vibe.load(id, fs.readFileSync(f, 'utf8'))
  console.log(id, r.ok ? 'loaded' : 'FAILED ' + r.error.slice(0, 400))
}
const cs = JSON.parse(ctx.__vibe.contributions())
const routes = cs.filter(c => c.area === 'routes')
console.log('routes:', routes.map(c => c.data.path).join(' '))
routes.forEach((c, i) => ctx.__vibe.mount('r' + i, 'route', c.data.path))
await new Promise(r => setTimeout(r, 600))
const types = new Map()
const walk = (n, f) => { f(n); (n.c || []).forEach(x => walk(x, f)) }
const short = (n, d = 0) => d > 7 ? '' : '  '.repeat(d) + (n.t === '#text' ? JSON.stringify(n.s).slice(0, 60) : n.t + (n.p?.className ? ' .' + n.p.className.slice(0, 70) : '')) + '\n' + (n.c || []).slice(0, 6).map(x => short(x, d + 1)).join('')
routes.forEach((c, i) => {
  const t = out['r' + i]
  console.log(`\n=== ${c.data.path}`)
  if (!t) return console.log('  (no render)')
  walk(t, n => types.set(n.t, (types.get(n.t) || 0) + 1))
  if (process.env.TREE) console.log(short(t))
  else console.log(short(t).split('\n').slice(0, 25).join('\n'))
  fs.writeFileSync(`/tmp/claude-1000/tree-${c.plugin}.json`, JSON.stringify(t, null, 1))
})
console.log('\nnode types:', [...types].sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k}:${v}`).join(' '))
process.exit(0)
