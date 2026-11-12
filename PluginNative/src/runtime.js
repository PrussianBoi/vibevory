/**
 * Native plugin runtime: runs Hermes Desktop disk plugins (plugin.js) in JavaScriptCore, with no
 * web view. Plugins render through a React renderer whose "DOM" is a plain tree, sent to Swift as
 * JSON after every commit; Swift draws it with native SwiftUI controls (PluginRenderer.swift).
 *
 * Swift provides `globalThis.__native` before this file runs:
 *   send(type, json)          one-way message: render | toast | navigate | openSession | log | contributions
 *   call(type, json, id)      async request; Swift answers with __vibe.resolve(id, ok, json)
 *   setTimer(id, ms, repeat)  clearTimer(id)     Swift calls __vibe.fire(id)
 *   storageGet(key) -> string|null              storageSet(key, string|null)
 *
 * API for Swift (globalThis.__vibe):
 *   start({ profile, gateway }) · load(id, source) -> {ok, error?} · contributions()
 *   mount(rootId, kind, key) (kind 'route' | 'pane')  unmount(rootId)
 *   dispatch(handlerId, argsJson)  resolve(id, ok, json)  fire(timerId)  setState(key, value)
 */
import './shims.js'
import * as React from 'react'
import * as JSX from 'react/jsx-runtime'
import Reconciler from 'react-reconciler'
import { DefaultEventPriority, ConcurrentRoot } from 'react-reconciler/constants'
import { QueryClient, QueryClientProvider, useMutation, useQuery, useQueryClient, useQueries, useInfiniteQuery, keepPreviousData } from '@tanstack/react-query'
import { atom } from 'nanostores'

const N = globalThis.__native
const { fireTimer, safeJson } = globalThis.__vibeShims

// ---- requests to Swift ---------------------------------------------------------------------------

const pending = new Map()
let callSeq = 1
function call(type, payload) {
  const id = String(callSeq++)
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject })
    N.call(type, JSON.stringify(payload ?? {}), id)
  })
}

class HttpError extends Error {
  constructor(status, message, body) { super(message); this.status = status; this.body = body }
}

async function api(path, opts = {}) {
  const body = opts.body === undefined ? undefined : typeof opts.body === 'string' ? opts.body : JSON.stringify(opts.body)
  const r = await call('api', { path, method: opts.method || 'GET', body, timeoutMs: opts.timeoutMs })
  if (r.error) throw new Error(r.error)
  let data = r.body
  try { data = r.body ? JSON.parse(r.body) : null } catch {}
  if (r.status >= 400) {
    const detail = data && typeof data === 'object' ? data.detail || data.error || data.message : data
    throw new HttpError(r.status, `${r.status}: ${typeof detail === 'string' ? detail : safeJson(detail)}`, data)
  }
  return data
}

// ---- host state (nanostores atoms, as the Desktop's) -------------------------------------------

const state = {
  profile: atom('default'),
  gateway: atom('open'),
  connectionId: atom('local'),
  cwd: atom(''),
  sessionId: atom(null),
  theme: atom('dark')
}
const stateProxy = new Proxy(state, { get: (t, k) => (k in t ? t[k] : (t[k] = atom(null))) })

function useValue(store) {
  const [, force] = React.useReducer(x => x + 1, 0)
  React.useEffect(() => (store && store.listen ? store.listen(() => force()) : undefined), [store])
  return store && store.get ? store.get() : undefined
}

const toast = (kind, a, b) => {
  const p = typeof a === 'object' && a ? a : { message: String(a ?? ''), ...(b || {}) }
  N.send('toast', JSON.stringify({ kind: p.kind || kind, title: p.title, message: p.message ?? p.description ?? '' }))
}

const hostBase = {
  state: stateProxy,
  notify: p => toast('info', p),
  notifyError: (e, title) => toast('error', { title, message: String(e?.message || e) }),
  navigate: path => N.send('navigate', JSON.stringify({ path })),
  openSession: (sessionId, opts) => N.send('openSession', JSON.stringify({ sessionId, opts: opts ?? null })),
  request: (method, params) => call('rpc', { method, params }).then(r => { if (r.error) throw new Error(r.error); return r.result }),
  requestProfile: (route, method, params) => hostBase.request(method, params),
  profileRoutes: async () => [{ profile: state.profile.get() }],
  retainProfile: async () => () => undefined,
  onEvent: () => () => undefined,
  openExternal: url => N.send('openExternal', JSON.stringify({ url })),
  copy: text => N.send('clipboard', JSON.stringify({ text }))
}
// Members this host doesn't have are harmless no-ops, not crashes.
const host = new Proxy(hostBase, {
  get: (t, k) => (k in t ? t[k] : typeof k === 'string' ? () => undefined : undefined)
})

// ---- the SDK -------------------------------------------------------------------------------------

/** SDK components are host elements: Swift draws each one natively under its name. */
const HOST_COMPONENTS = [
  'Badge', 'Button', 'Checkbox', 'Codicon', 'ConfirmDialog', 'CopyButton', 'Dialog', 'DialogContent', 'DialogDescription',
  'DialogFooter', 'DialogHeader', 'DialogTitle', 'DisclosureCaret', 'DropdownMenu', 'DropdownMenuContent',
  'DropdownMenuItem', 'DropdownMenuLabel', 'DropdownMenuSeparator', 'DropdownMenuTrigger', 'EmptyState', 'ErrorState',
  'GlyphSpinner', 'Input', 'Kbd', 'KbdGroup', 'Loader', 'LogView', 'Popover', 'PopoverContent', 'PopoverTrigger',
  'RowButton', 'ScrollArea', 'SearchField', 'SegmentedControl', 'Select', 'SelectContent', 'SelectItem',
  'SelectTrigger', 'SelectValue', 'Separator', 'Skeleton', 'StatusDot', 'Switch', 'Tabs', 'TabsList', 'TabsTrigger',
  'Textarea', 'Tip', 'Tooltip', 'TooltipContent', 'TooltipTrigger', 'TooltipProvider', 'FadeScroll', 'MessageTextContent'
]

const sdkBase = {
  host,
  useValue,
  useMutation, useQuery, useQueryClient, useQueries, useInfiniteQuery, keepPreviousData,
  ROUTES_AREA: 'routes',
  SIDEBAR_NAV_AREA: 'sidebar.nav',
  PALETTE_AREA: 'palette',
  PANES_AREA: 'panes',
  STATUSBAR_AREAS: { left: 'statusbar.left', right: 'statusbar.right' },
  TITLEBAR_AREAS: { left: 'titlebar.left', right: 'titlebar.right' },
  cn: (...a) => a.flat(Infinity).filter(Boolean).join(' '),
  haptic: () => {}
}
for (const name of HOST_COMPONENTS) sdkBase[name] = name
const sdk = new Proxy(sdkBase, {
  get: (t, k) => (k in t ? t[k] : typeof k === 'string' && /^[A-Z]/.test(k) ? k : undefined)
})

// ---- the renderer --------------------------------------------------------------------------------

const handlers = new Map()   // rootId -> Map(handler id -> fn), rebuilt on every commit of that root
let handlerSeq = 1
let handlerRoot = null
let nodeSeq = 1

function cleanProps(props) {
  const out = {}
  for (const k in props) {
    if (k === 'children' || k === 'key' || k === 'ref') continue
    const v = props[k]
    if (v === undefined) continue
    out[k] = v
  }
  return out
}

/** Children that are plain strings/numbers are kept on the node (React sets them as text). */
function textOf(props) {
  const c = props.children
  return typeof c === 'string' || typeof c === 'number' ? String(c) : null
}

const roots = new Map()      // rootId -> { container, fiber, dirty }

function serialize(node) {
  if (node.text !== undefined && node.type === '#text') return { t: '#text', s: node.text }
  const p = {}
  for (const k in node.props) {
    const v = node.props[k]
    if (typeof v === 'function') {
      const id = `${handlerRoot}:${handlerSeq++}`
      handlers.get(handlerRoot).set(id, v)
      p[k] = { $fn: id }
    } else if (v && typeof v === 'object' && React.isValidElement(v)) {
      p[k] = { $el: renderDetached(v) }
    } else {
      p[k] = plain(v)
    }
  }
  const out = { t: node.type, i: node.id, p }
  const text = node.inline
  if (text != null) out.c = [{ t: '#text', s: text }]
  else if (node.children.length) out.c = node.children.filter(c => !c.hidden).map(serialize)
  return out
}

function plain(v, depth = 0) {
  if (v == null || typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') return v
  if (depth > 6) return null
  if (Array.isArray(v)) return v.map(x => plain(x, depth + 1))
  if (typeof v === 'function') return null
  if (typeof v === 'object') {
    const o = {}
    for (const k in v) o[k] = plain(v[k], depth + 1)
    return o
  }
  return null
}

/** Elements passed as props (icons, Tip content): a text summary is enough for native views. */
function renderDetached(el) {
  const parts = []
  const walk = e => {
    if (e == null || typeof e === 'boolean') return
    if (typeof e === 'string' || typeof e === 'number') return parts.push(String(e))
    if (Array.isArray(e)) return e.forEach(walk)
    if (React.isValidElement(e)) {
      if (typeof e.type === 'string' && e.type === 'Codicon') return parts.push(`[${e.props.name}]`)
      return walk(e.props?.children)
    }
  }
  walk(el)
  return parts.join('')
}

function flush(rootId) {
  const r = roots.get(rootId)
  if (!r) return
  handlers.set(rootId, new Map())
  handlerRoot = rootId
  handlerSeq = 1
  const tree = { t: 'root', i: 0, p: {}, c: r.container.children.filter(c => !c.hidden).map(serialize) }
  N.send('render', JSON.stringify({ root: rootId, tree }))
}

let currentPriority = DefaultEventPriority
const hostConfig = {
  supportsMutation: true,
  supportsPersistence: false,
  supportsHydration: false,
  isPrimaryRenderer: true,
  noTimeout: -1,
  scheduleTimeout: (fn, ms) => setTimeout(fn, ms),
  cancelTimeout: id => clearTimeout(id),
  supportsMicrotasks: true,
  scheduleMicrotask: fn => queueMicrotask(fn),
  getRootHostContext: () => ({}),
  getChildHostContext: ctx => ctx,
  getPublicInstance: i => i,
  prepareForCommit: () => null,
  resetAfterCommit: container => flush(container.rootId),
  preparePortalMount: () => {},
  shouldSetTextContent: (type, props) => textOf(props) !== null,
  createInstance: (type, props) => ({ id: nodeSeq++, type, props: cleanProps(props), inline: textOf(props), children: [] }),
  createTextInstance: text => ({ id: nodeSeq++, type: '#text', text, props: {}, children: [] }),
  appendInitialChild: (p, c) => p.children.push(c),
  appendChild: (p, c) => { remove(p, c); p.children.push(c) },
  appendChildToContainer: (p, c) => { remove(p, c); p.children.push(c) },
  insertBefore: (p, c, before) => { remove(p, c); p.children.splice(p.children.indexOf(before), 0, c) },
  insertInContainerBefore: (p, c, before) => { remove(p, c); p.children.splice(p.children.indexOf(before), 0, c) },
  removeChild: remove,
  removeChildFromContainer: remove,
  clearContainer: container => { container.children = [] },
  finalizeInitialChildren: () => false,
  commitUpdate: (inst, type, oldProps, newProps) => { inst.props = cleanProps(newProps); inst.inline = textOf(newProps) },
  commitTextUpdate: (inst, oldText, newText) => { inst.text = newText },
  resetTextContent: () => {},
  hideInstance: i => { i.hidden = true },
  unhideInstance: i => { i.hidden = false },
  hideTextInstance: i => { i.hidden = true },
  unhideTextInstance: i => { i.hidden = false },
  detachDeletedInstance: () => {},
  getInstanceFromNode: () => null,
  beforeActiveInstanceBlur: () => {},
  afterActiveInstanceBlur: () => {},
  prepareScopeUpdate: () => {},
  getInstanceFromScope: () => null,
  setCurrentUpdatePriority: p => { currentPriority = p },
  getCurrentUpdatePriority: () => currentPriority,
  resolveUpdatePriority: () => currentPriority || DefaultEventPriority,
  maySuspendCommit: () => false,
  preloadInstance: () => true,
  startSuspendingCommit: () => {},
  suspendInstance: () => {},
  waitForCommitToBeReady: () => null,
  shouldAttemptEagerTransition: () => false,
  requestPostPaintCallback: () => {},
  trackSchedulerEvent: () => {},
  resolveEventType: () => null,
  resolveEventTimeStamp: () => -1.1,
  NotPendingTransition: null,
  HostTransitionContext: React.createContext(null),
  resetFormInstance: () => {}
}
function remove(p, c) {
  const i = p.children.indexOf(c)
  if (i >= 0) p.children.splice(i, 1)
}

const reconciler = Reconciler(hostConfig)

// ---- plugins -------------------------------------------------------------------------------------

const queryClient = new QueryClient({ defaultOptions: { queries: { retry: 1, refetchOnWindowFocus: false } } })
const contributions = []      // { plugin, id, area, order, title, data, render }
const disposers = new Map()   // plugin -> [fn]

function pluginContext(pluginId) {
  const scope = c => ({ ...c, id: `${pluginId}:${c.id}`, plugin: pluginId })
  const track = fn => { (disposers.get(pluginId) || disposers.set(pluginId, []).get(pluginId)).push(fn); return fn }
  const register = c => { const s = scope(c); contributions.push(s); return () => { const i = contributions.indexOf(s); if (i >= 0) contributions.splice(i, 1) } }
  const storageKey = k => `hermes.plugin.${pluginId}.${k}`
  const ctx = {
    source: `plugin:${pluginId}`,
    register,
    registerMany: cs => { const ds = cs.map(register); return () => ds.forEach(d => d()) },
    registerSettingsPage: () => () => undefined,
    onDispose: fn => void track(fn),
    onEvent: () => () => undefined,
    setTimeout: (fn, ms) => { const id = setTimeout(fn, ms); return track(() => clearTimeout(id)) },
    setInterval: (fn, ms) => { const id = setInterval(fn, ms); return track(() => clearInterval(id)) },
    addEventListener: () => () => undefined,
    rest: (path, opts) => api(`/api/plugins/${pluginId}${path.startsWith('/') ? path : '/' + path}`, opts),
    socket: () => () => undefined,
    os: {
      notify: p => { toast('info', p); return { ok: true } },
      openExternal: url => { host.openExternal(url); return { ok: true } },
      copy: text => { host.copy(text); return { ok: true } },
      writeClipboard: text => { host.copy(text); return { ok: true } },
      revealPath: path => { N.send('revealPath', JSON.stringify({ path })); return { ok: true } }
    },
    pet: { say: () => {} },
    runAction: () => ({ ok: false, error: 'Not available in this app' }),
    listActions: () => [],
    storage: {
      get(key, fallback) {
        const raw = N.storageGet(storageKey(key))
        if (raw == null) return fallback
        try { return JSON.parse(raw) } catch { return fallback }
      },
      set: (key, value) => N.storageSet(storageKey(key), JSON.stringify(value)),
      remove: key => N.storageSet(storageKey(key), null)
    },
    i18n: { register: () => () => undefined, t: k => k }
  }
  return new Proxy(ctx, { get: (t, k) => (k in t ? t[k] : typeof k === 'string' ? () => () => undefined : undefined) })
}

/** ESM plugin source -> a function body: the three allowed imports become lookups, the default export a return. */
function toFunctionBody(source) {
  const modules = { '@hermes/plugin-sdk': '__sdk', react: '__react', 'react/jsx-runtime': '__jsx', 'react/jsx-dev-runtime': '__jsx' }
  let body = source.replace(/import\s*\{([^}]*)\}\s*from\s*['"]([^'"]+)['"];?/g, (m, names, spec) => {
    const target = modules[spec]
    if (!target) throw new Error(`Unsupported import: ${spec}`)
    const fixed = names.split(',').map(s => s.trim()).filter(Boolean).map(s => s.replace(/\s+as\s+/, ': ')).join(', ')
    return `const { ${fixed} } = ${target};`
  })
  body = body.replace(/import\s+\*\s+as\s+(\w+)\s+from\s*['"]([^'"]+)['"];?/g, (m, name, spec) => `const ${name} = ${modules[spec] || 'undefined'};`)
  body = body.replace(/import\s+(\w+)\s+from\s*['"]([^'"]+)['"];?/g, (m, name, spec) => `const ${name} = ${modules[spec] || 'undefined'};`)
  body = body.replace(/export\s+default\s+/, 'return ')
  body = body.replace(/^export\s+(const|let|var|function|class)\s/gm, '$1 ')
  return body
}

const reactNs = { ...React, default: React }
function load(id, source) {
  try {
    const factory = new Function('__sdk', '__react', '__jsx', toFunctionBody(source) + `\n//# sourceURL=${id}/plugin.js`)
    const plugin = factory(sdk, reactNs, JSX)
    if (!plugin || typeof plugin.register !== 'function') throw new Error('plugin.js has no default export with register()')
    plugin.register(pluginContext(plugin.id || id))
    N.send('contributions', JSON.stringify(listContributions()))
    return { ok: true, pluginId: plugin.id || id, name: plugin.name || null }
  } catch (e) {
    return { ok: false, error: String(e && e.stack ? e.message + '\n' + e.stack : e) }
  }
}

function listContributions() {
  return contributions.map(c => ({
    id: c.id, plugin: c.plugin, area: c.area, order: c.order ?? null, title: c.title ?? null,
    data: plain({ ...(c.data || {}), run: undefined }), hasRender: typeof c.render === 'function'
  }))
}

class Boundary extends React.Component {
  constructor(p) { super(p); this.state = { error: null } }
  static getDerivedStateFromError(error) { return { error } }
  render() {
    if (this.state.error) {
      return React.createElement('EmptyState', { title: 'This plugin page crashed', description: String(this.state.error?.message || this.state.error) })
    }
    return this.props.children
  }
}

function findContribution(kind, key) {
  if (kind === 'route') return contributions.find(c => c.area === 'routes' && c.data?.path === key && c.render)
  return contributions.find(c => c.id === key && c.render)
}

function mount(rootId, kind, key) {
  unmount(rootId)
  const c = findContribution(kind, key)
  if (!c) return false
  const container = { rootId, children: [] }
  const fiber = reconciler.createContainer(container, ConcurrentRoot, null, false, null, rootId, e => console.error(String(e)), e => console.error(String(e)), e => console.error(String(e)), null)
  roots.set(rootId, { container, fiber })
  const Render = () => c.render({})
  reconciler.updateContainer(
    React.createElement(QueryClientProvider, { client: queryClient }, React.createElement(Boundary, null, React.createElement(Render))),
    fiber, null, null)
  return true
}

function unmount(rootId) {
  const r = roots.get(rootId)
  if (!r) return
  roots.delete(rootId)
  handlers.delete(rootId)
  reconciler.updateContainer(null, r.fiber, null, null)
}

/** A native control's event, as the plugin's handler expects it. */
function dispatch(id, argsJson) {
  const fn = handlers.get(String(id).split(':')[0])?.get(id)
  if (!fn) return
  let args = []
  try { args = JSON.parse(argsJson || '[]') } catch {}
  const event = a => {
    if (a && typeof a === 'object' && 'value' in a) {
      const target = { value: a.value, checked: a.checked }
      return { target, currentTarget: target, key: a.key, preventDefault() {}, stopPropagation() {}, nativeEvent: {} }
    }
    if (a && typeof a === 'object' && a.$event) {
      return { key: a.key, shiftKey: !!a.shiftKey, metaKey: !!a.metaKey, target: {}, currentTarget: {}, preventDefault() {}, stopPropagation() {}, nativeEvent: {} }
    }
    return a
  }
  reconciler.discreteUpdates ? reconciler.discreteUpdates(() => fn(...args.map(event))) : fn(...args.map(event))
}

function runPalette(id) {
  const c = contributions.find(x => x.area === 'palette' && (x.id === id || x.data?.id === id))
  if (c && typeof c.data?.run === 'function') c.data.run()
}

globalThis.__vibe = {
  start({ profile, gateway } = {}) {
    if (profile) state.profile.set(profile)
    if (gateway) state.gateway.set(gateway)
  },
  setState(key, value) { stateProxy[key].set(value) },
  load,
  contributions: () => JSON.stringify(listContributions()),
  mount,
  unmount,
  dispatch,
  runPalette,
  resolve(id, ok, json) {
    const p = pending.get(id)
    if (!p) return
    pending.delete(id)
    let v = null
    try { v = JSON.parse(json) } catch {}
    ok ? p.resolve(v) : p.reject(new Error(typeof v === 'string' ? v : safeJson(v)))
  },
  fire: fireTimer
}
