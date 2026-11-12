// Clicks the Workflows "running" filter and the second run row through dispatch(), as Swift would.
import fs from 'node:fs'
import vm from 'node:vm'
const fixtures = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))
let tree = null
const timers = new Map()
const ctx = {}
ctx.__native = {
  send(type, json) { if (type === 'render') tree = JSON.parse(json).tree },
  call(type, json, id) {
    const req = JSON.parse(json)
    const key = Object.keys(fixtures).find(k => req.path.startsWith(k))
    setTimeout(() => ctx.__vibe.resolve(id, true, JSON.stringify(key ? { status: 200, body: JSON.stringify(fixtures[key]) } : { status: 404, body: '{}' })), 5)
  },
  setTimer(id, ms, rep) { timers.set(id, (rep ? setInterval : setTimeout)(() => ctx.__vibe.fire(id), Math.min(ms, 50))) },
  clearTimer(id) { clearTimeout(timers.get(id)); clearInterval(timers.get(id)) },
  storageGet: () => null, storageSet() {}
}
vm.createContext(ctx)
vm.runInContext(fs.readFileSync('../VoryMac/Plugins/plugin-runtime.js', 'utf8'), ctx)
ctx.__vibe.load('workflows', fs.readFileSync(process.env.HOME + '/.hermes/desktop-plugins/workflows/plugin.js', 'utf8'))
ctx.__vibe.mount('page', 'route', '/workflows')
const wait = ms => new Promise(r => setTimeout(r, ms))
const all = (n, f, out = []) => { if (f(n)) out.push(n); (n.c || []).forEach(c => all(c, f, out)); return out }
const text = n => n.s ?? (n.c || []).map(text).join('')
await wait(1200)
const filters = () => all(tree, n => n.t === 'Button' && ['all', 'running', 'done', 'failed'].includes(text(n)))
console.log('filters before:', filters().map(b => text(b) + '=' + b.p.variant).join(' '))
console.log('agent rows before:', all(tree, n => n.t === 'button' && /#\d/.test(text(n))).length)
ctx.__vibe.dispatch(filters().find(b => text(b) === 'running').p.onClick.$fn, '[{"$event":true}]')
await wait(100)
console.log('filters after:', filters().map(b => text(b) + '=' + b.p.variant).join(' '))
console.log('agent rows after:', all(tree, n => n.t === 'button' && /#\d/.test(text(n))).length)
const rows = all(tree, n => n.t === 'button' && (n.p.className || '').includes('flex-col'))
console.log('selected row:', rows.map(r => (r.p.className.includes('selected') ? '*' : '') + text(r).slice(0, 20)).join(' | '))
ctx.__vibe.dispatch(rows[2].p.onClick.$fn, '[{"$event":true}]')
await wait(100)
console.log('after click:', all(tree, n => n.t === 'button' && (n.p.className || '').includes('flex-col')).map(r => (r.p.className.includes('selected') ? '*' : '') + text(r).slice(0, 20)).join(' | '))
process.exit(0)
