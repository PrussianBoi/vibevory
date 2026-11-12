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
