// Platform shims JavaScriptCore lacks (timers, console). Imported first: React's scheduler reads
// setTimeout when it loads.
const N = globalThis.__native

// ---- platform shims (timers, console, microtasks) ----------------------------------------------

const timers = new Map()
let timerSeq = 1
function addTimer(fn, ms, repeat, args) {
  const id = timerSeq++
  timers.set(id, { fn, args, repeat })
  N.setTimer(id, Math.max(0, Number(ms) || 0), !!repeat)
  return id
}
function clearTimer(id) {
  if (timers.delete(id)) N.clearTimer(id)
}
globalThis.setTimeout = (fn, ms, ...args) => addTimer(fn, ms, false, args)
globalThis.setInterval = (fn, ms, ...args) => addTimer(fn, ms, true, args)
globalThis.clearTimeout = clearTimer
globalThis.clearInterval = clearTimer
globalThis.queueMicrotask ??= fn => Promise.resolve().then(fn)
globalThis.requestAnimationFrame ??= fn => addTimer(() => fn(Date.now()), 16, false, [])
globalThis.cancelAnimationFrame ??= clearTimer
const say = level => (...a) => N.send('log', JSON.stringify({ level, text: a.map(x => (typeof x === 'string' ? x : safeJson(x))).join(' ') }))
globalThis.console = { log: say('log'), info: say('info'), debug: say('debug'), warn: say('warn'), error: say('error') }
globalThis.window ??= globalThis
globalThis.navigator ??= { clipboard: { writeText: async text => N.send('clipboard', JSON.stringify({ text })) }, platform: 'MacIntel', userAgent: 'Hermes' }
globalThis.AbortController ??= class { constructor() { this.signal = { aborted: false, addEventListener() {}, removeEventListener() {} } } abort() { this.signal.aborted = true } }
globalThis.URLSearchParams ??= class URLSearchParams {
  constructor(init) {
    this._p = []
    if (typeof init === 'string') {
      for (const part of init.replace(/^\?/, '').split('&')) {
        if (!part) continue
        const i = part.indexOf('=')
        const dec = s => decodeURIComponent(s.replace(/\+/g, ' '))
        this._p.push(i < 0 ? [dec(part), ''] : [dec(part.slice(0, i)), dec(part.slice(i + 1))])
      }
    } else if (init && typeof init[Symbol.iterator] === 'function') {
      for (const [k, v] of init) this._p.push([String(k), String(v)])
    } else if (init && typeof init === 'object') {
      for (const k of Object.keys(init)) this._p.push([k, String(init[k])])
    }
  }
  append(k, v) { this._p.push([String(k), String(v)]) }
  set(k, v) { k = String(k); const i = this._p.findIndex(p => p[0] === k); this._p = this._p.filter((p, j) => p[0] !== k || j === i); if (i < 0) this._p.push([k, String(v)]); else this._p[this._p.findIndex(p => p[0] === k)][1] = String(v) }
  get(k) { const p = this._p.find(p => p[0] === String(k)); return p ? p[1] : null }
  getAll(k) { return this._p.filter(p => p[0] === String(k)).map(p => p[1]) }
  has(k) { return this._p.some(p => p[0] === String(k)) }
  delete(k) { this._p = this._p.filter(p => p[0] !== String(k)) }
  sort() { this._p.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)) }
  forEach(fn, self) { for (const [k, v] of this._p) fn.call(self, v, k, this) }
  keys() { return this._p.map(p => p[0])[Symbol.iterator]() }
  values() { return this._p.map(p => p[1])[Symbol.iterator]() }
  entries() { return this._p.map(p => [p[0], p[1]])[Symbol.iterator]() }
  [Symbol.iterator]() { return this.entries() }
  get size() { return this._p.length }
  toString() {
    const enc = s => encodeURIComponent(s).replace(/%20/g, '+')
    return this._p.map(([k, v]) => `${enc(k)}=${enc(v)}`).join('&')
  }
}
globalThis.addEventListener ??= () => {}
globalThis.removeEventListener ??= () => {}

function safeJson(v) {
  try { return JSON.stringify(v) } catch { return String(v) }
}

function fireTimer(id) {
  const t = timers.get(id)
  if (!t) return
  if (!t.repeat) timers.delete(id)
  t.fn(...(t.args || []))
}

globalThis.__vibeShims = { addTimer, clearTimer, fireTimer, safeJson }
