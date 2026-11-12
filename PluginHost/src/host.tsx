/**
 * VibeVory plugin host: runs Hermes Desktop disk plugins (plugin.js) outside Electron, one
 * surface per page, for WKWebView embedding. Reuses the Desktop's real SDK, runtime loader,
 * contribution registry, gateway client, theme engine and UI components.
 *
 * JS API (window.VibePluginHost):
 *   start({ gatewayUrl, token, profile?, auth?, transport?, theme?, inPageToasts?, plugins: [{ id, source, file?, enabled? }] })
 *       -> Promise<{ plugins: [{ id, pluginId, ok, status, error? }], contributions }>
 *   listContributions() -> { routes, sidebarNav, palette, panes, statusBar }  (each: id, plugin, area,
 *       title?, label?, icon? (codicon), path?, order?, keywords?, placement?, width?, command?)
 *   mount({ kind: 'route', path } | { kind: 'pane', id } | { kind: 'status', id } | { kind: 'none' })
 *   runPalette(idOrCommand) -> boolean        listPlugins()         setPluginEnabled(id, on)
 *   addPlugin({ id, source, enabled? })       removePlugin(pluginId)
 *   gatewayState()                            resolveNative(requestId, result)
 *
 * Messages to native (window.webkit.messageHandlers.vibe.postMessage({ type, ... })):
 *   loaded {version} | ready {plugins, contributions} | contributions {contributions}
 *   contributionsChanged {} | gatewayState {state} | route {path, search, matched}
 *   navigate {path}            a plugin called host.navigate(path)
 *   toast {id, kind, title?, message, detail?}
 *   openExternal {url} | notify {payload} | clipboard.write {text} | revealPath {path}
 *   openSession {sessionId, opts}
 *   Request/response (native must answer VibePluginHost.resolveNative(requestId, result)):
 *   api {requestId, url, method, headers, body?, bodyBase64?, uploadFilename?, uploadContentType?, timeoutMs}
 *       -> { status, body, statusText? } | { error }
 *   pickOpenPath {requestId, options} -> string[]      pickSavePath {requestId, options} -> string | null
 */

// MUST stay the first import: installs the fake `window.hermesDesktop` before any Desktop module runs.
import { gatewayWsUrl, hasNative, missingBridgeMembers, postNative, setHostConfig, settleNative } from './bridge'
import './host.css'

import { QueryClientProvider } from '@tanstack/react-query'
import { StrictMode, useEffect, useMemo, useReducer } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { HashRouter, useLocation } from 'react-router'

import { setApiRequestProfile } from '@/api/client'
import { HermesGateway } from '@/hermes'
import { ROUTES_AREA, SIDEBAR_NAV_AREA } from '@/app/routes'
import { PALETTE_AREA } from '@/app/command-palette/contrib'
import { RootErrorBoundary } from '@/components/error-boundary'
import { NotificationStack } from '@/components/notifications'
import { RootTooltipProvider } from '@/components/ui/tooltip'
import { emitGatewayEvent } from '@/contrib/events'
import { $pluginRecords, setPluginEnabled } from '@/contrib/plugins-store'
import { ContribBoundary, ContribRender } from '@/contrib/react/boundary'
import { useContributions } from '@/contrib/react/use-contributions'
import { registry } from '@/contrib/registry'
import { loadRuntimePlugin, unloadRuntimePlugin } from '@/contrib/runtime-loader'
import type { Contribution } from '@/contrib/types'
import { ProfileI18nProvider } from '@/i18n/profile-provider'
import { queryClient } from '@/lib/query-client'
import { PANES_AREA, STATUSBAR_AREAS } from '@/sdk/areas'
import { installPluginSdk } from '@/sdk/runtime'
import { $gateway, reportPrimaryGatewayState, setPrimaryGateway } from '@/store/gateway'
import { $notifications } from '@/store/notifications'
import { $activeGatewayProfile } from '@/store/profile'
import { $gatewayState } from '@/store/session'
import { ThemeProvider } from '@/themes/context'

// ---- types ------------------------------------------------------------------------------------

export interface StartOptions {
  /** Hermes dashboard/gateway base URL, e.g. `http://127.0.0.1:9119`. */
  gatewayUrl: string
  /** Dashboard session token (sent as `X-Hermes-Session-Token` and `?token=` on /api/ws). */
  token: string
  /** Profile name the gateway serves (host.state.profile). Default `default`. */
  profile?: string
  /** How REST reaches the gateway. `native` (default inside WKWebView): every call is posted to
   *  the Swift side as an `api` message, which avoids CORS from a file:// page. `fetch`: direct
   *  fetch() from the page (only works when the page origin is allowed by the backend). */
  transport?: 'fetch' | 'native'
  /** `session-token` (default): X-Hermes-Session-Token header + `?token=` on /api/ws.
   *  `bearer`: `token` is an OAuth access token (Authorization: Bearer) and each WebSocket dial
   *  mints a single-use ticket via POST /api/auth/ws-ticket — for OAuth-gated dashboards. */
  auth?: 'bearer' | 'session-token'
  /** Render toasts (host.notify / plugin errors) inside the page. Default true. Every toast is
   *  also posted to native as a `toast` message either way. */
  inPageToasts?: boolean
  /** `dark` (default), `light` or `system`. */
  theme?: 'dark' | 'light' | 'system'
  /** Plugin sources (the contents of each plugin.js). `id` is a label for errors only.
   *  `enabled` overrides the plugin's own `defaultEnabled` (e.g. code-workflows ships opt-in);
   *  omit it to keep the Desktop rule (stored choice in this WebView, else the plugin default). */
  plugins?: PluginInput[]
}

export interface PluginInput {
  id: string
  source: string
  file?: string
  enabled?: boolean
}

export type MountTarget =
  | { kind: 'route'; path: string }
  | { kind: 'pane'; id: string }
  | { kind: 'status'; id: string }
  | { kind: 'none' }

interface ContributionInfo {
  id: string
  plugin: string
  area: string
  title?: string
  label?: string
  icon?: string
  path?: string
  order?: number
  keywords?: string[]
  placement?: string
  width?: string
  /** Palette rows: the command id to pass to runPalette(). */
  command?: string
}

// ---- gateway ----------------------------------------------------------------------------------

let gateway: HermesGateway | null = null
let reconnectTimer: ReturnType<typeof setTimeout> | undefined
let reconnectAttempt = 0
let stopped = false

function startGateway(profile: string) {
  const gw = new HermesGateway()
  gateway = gw
  setPrimaryGateway(gw, profile)
  ;($gateway as unknown as { set: (value: HermesGateway) => void }).set(gw)

  gw.onState(state => {
    reportPrimaryGatewayState(state)
    postNative('gatewayState', { state })

    if (state === 'open') {
      reconnectAttempt = 0
    } else if ((state === 'closed' || state === 'error') && !stopped) {
      scheduleReconnect()
    }
  })
  // Same fan-out as the app's gateway boot: plugins hear it through ctx.onEvent / host.onEvent.
  gw.onEvent(event => emitGatewayEvent({ ...event, profile } as typeof event))

  void dial()
}

async function dial() {
  if (!gateway || gateway.connectionState === 'open' || gateway.connectionState === 'connecting') {
    return
  }

  try {
    await gateway.connect(await gatewayWsUrl())
  } catch (error) {
    console.warn('[vibe] gateway connect failed:', error instanceof Error ? error.message : error)
    scheduleReconnect()
  }
}

function scheduleReconnect() {
  if (reconnectTimer || stopped || !gateway) {
    return
  }

  const delay = Math.min(30_000, 1000 * 2 ** reconnectAttempt) * (0.5 + Math.random() / 2)
  reconnectAttempt += 1
  reconnectTimer = setTimeout(() => {
    reconnectTimer = undefined
    void dial()
  }, delay)
}

const str = (value: unknown) => (typeof value === 'string' ? value : undefined)

// ---- contributions ----------------------------------------------------------------------------

const pluginOf = (c: Contribution) => (c.source ?? 'core').replace(/^plugin:/, '')

const AREAS = {
  routes: ROUTES_AREA,
  sidebarNav: SIDEBAR_NAV_AREA,
  palette: PALETTE_AREA,
  panes: PANES_AREA,
  statusLeft: STATUSBAR_AREAS.left,
  statusRight: STATUSBAR_AREAS.right
} as const

function describe(c: Contribution): ContributionInfo {
  const data = (c.data ?? {}) as Record<string, unknown>

  return {
    id: c.id,
    plugin: pluginOf(c),
    area: c.area,
    title: c.title,
    label: str(data.label),
    icon: str(data.codicon) ?? str(data.icon),
    path: str(data.path),
    order: c.order,
    keywords: Array.isArray(data.keywords) ? (data.keywords as string[]) : undefined,
    placement: str(data.placement),
    width: str(data.width),
    command: c.area === PALETTE_AREA ? str(data.id) : undefined
  }
}

function listContributions() {
  const pick = (area: string) => registry.getArea(area).map(describe)

  return {
    routes: pick(AREAS.routes),
    sidebarNav: pick(AREAS.sidebarNav),
    palette: pick(AREAS.palette),
    panes: pick(AREAS.panes),
    statusBar: [...pick(AREAS.statusLeft), ...pick(AREAS.statusRight)]
  }
}

function runPalette(id: string): boolean {
  const entry = registry
    .getArea(PALETTE_AREA)
    .find(c => c.id === id || (c.data as { id?: string } | undefined)?.id === id)
  const run = (entry?.data as { run?: () => void } | undefined)?.run

  if (!run) {
    return false
  }

  run()

  return true
}

// ---- React surface ----------------------------------------------------------------------------

let currentTarget: MountTarget = { kind: 'none' }
let showToasts = true
let mountedPath: null | string = null
let rerender: (() => void) | null = null

function matchRoute(routes: readonly Contribution[], pathname: string) {
  return routes.find(c => {
    const path = (c.data as { path?: string } | undefined)?.path

    return Boolean(path && c.render && (pathname === path || pathname.startsWith(`${path}/`)))
  })
}

function RouteSurface() {
  const location = useLocation()
  const routes = useContributions(ROUTES_AREA)
  const route = matchRoute(routes, location.pathname)

  useEffect(() => {
    postNative('route', { path: location.pathname, search: location.search, matched: Boolean(route) })
  }, [location.pathname, location.search, route])

  if (!route) {
    return <Waiting label={`No plugin route registered for ${location.pathname}`} />
  }

  const key = `${route.source ?? 'core'}:${route.id}`

  return (
    <div className="contents" data-vibe-surface="route">
      <ContribBoundary id={key}>
        <ContribRender key={key} render={route.render!} />
      </ContribBoundary>
    </div>
  )
}

function SingleSurface({ area, id, variant }: { area: string[]; id: string; variant: 'pane' | 'chip' }) {
  const a = useContributions(area[0])
  const b = useContributions(area[1] ?? area[0])
  const match = useMemo(() => [...a, ...b].find(c => c.id === id && c.render), [a, b, id])

  if (!match) {
    return <Waiting label={`No contribution "${id}"`} />
  }

  const body = (
    <ContribBoundary id={match.id} variant={variant}>
      <ContribRender key={match.id} render={match.render!} />
    </ContribBoundary>
  )

  return variant === 'chip' ? (
    <div className="flex h-full w-full items-center gap-1 px-2 text-xs text-(--ui-text-secondary)" data-vibe-surface="status">
      {body}
    </div>
  ) : (
    <div className="flex h-full w-full flex-col overflow-hidden" data-vibe-surface="pane">
      {body}
    </div>
  )
}

function Waiting({ label }: { label: string }) {
  return <div className="grid h-full place-items-center p-6 text-sm text-(--ui-text-tertiary)">{label}</div>
}

function Surface() {
  const target = currentTarget

  switch (target.kind) {
    case 'route':
      return <RouteSurface />
    case 'pane':
      return <SingleSurface area={[PANES_AREA]} id={target.id} variant="pane" />
    case 'status':
      return <SingleSurface area={[STATUSBAR_AREAS.right, STATUSBAR_AREAS.left]} id={target.id} variant="chip" />
    default:
      return null
  }
}

function HostRoot() {
  const [, force] = useForce()

  useEffect(() => {
    rerender = force

    return () => {
      rerender = null
    }
  }, [force])

  return (
    <div className="h-full w-full overflow-auto">
      <Surface />
      {showToasts && <NotificationStack />}
    </div>
  )
}

function useForce(): [number, () => void] {
  const [n, bump] = useReducer((x: number) => x + 1, 0)

  return [n, bump as () => void]
}

let root: Root | null = null

function renderRoot() {
  if (root) {
    return
  }

  root = createRoot(document.getElementById('root')!)
  root.render(
    <StrictMode>
      <RootErrorBoundary>
        <QueryClientProvider client={queryClient}>
          <ProfileI18nProvider>
            <ThemeProvider>
              <RootTooltipProvider>
                <HashRouter useTransitions={false}>
                  <HostRoot />
                </HashRouter>
              </RootTooltipProvider>
            </ThemeProvider>
          </ProfileI18nProvider>
        </QueryClientProvider>
      </RootErrorBoundary>
    </StrictMode>
  )
}

// ---- public API -------------------------------------------------------------------------------

const MODE_KEY = 'hermes-desktop-mode-v1'
let started: Promise<unknown> | null = null
const loadedIds = new Set<string>()

async function loadPlugins(plugins: PluginInput[]) {
  const results: Array<{ id: string; pluginId: null | string; ok: boolean; status: string; error?: string }> = []

  for (const plugin of plugins) {
    const pluginId = await loadRuntimePlugin(plugin.source, plugin.id, {
      file: plugin.file ?? `vibe://${plugin.id}/plugin.js`,
      kind: 'disk'
    })
    if (pluginId) {
      loadedIds.add(pluginId)

      if (typeof plugin.enabled === 'boolean') {
        await setPluginEnabled(pluginId, plugin.enabled)
      }
    }

    const record = pluginId ? $pluginRecords.get()[pluginId] : $pluginRecords.get()[plugin.id]

    results.push({
      id: plugin.id,
      pluginId,
      ok: Boolean(pluginId) && record?.status === 'loaded',
      status: record?.status ?? 'error',
      error: record?.error
    })
  }

  postNative('contributions', { contributions: listContributions() })

  return results
}

function start(options: StartOptions) {
  if (started) {
    throw new Error('VibePluginHost.start() was already called; reload the page to restart')
  }

  if (!options?.gatewayUrl || typeof options.token !== 'string') {
    throw new Error('VibePluginHost.start({ gatewayUrl, token }) is required')
  }

  const profile = options.profile || 'default'
  showToasts = options.inPageToasts ?? true

  try {
    window.localStorage.setItem(MODE_KEY, options.theme ?? 'dark')
  } catch {
    // storage blocked — ThemeProvider falls back to the OS appearance
  }

  setHostConfig({
    gatewayUrl: options.gatewayUrl,
    token: options.token,
    profile,
    transport: options.transport ?? (hasNative() ? 'native' : 'fetch'),
    auth: options.auth ?? 'session-token'
  })
  installPluginSdk()
  $activeGatewayProfile.set(profile)
  setApiRequestProfile(profile === 'default' ? null : profile)

  startGateway(profile)
  renderRoot()

  // Toasts render in-page (NotificationStack) and are mirrored to the native side.
  let seen = new Set<string>()
  $notifications.subscribe(list => {
    const next = new Set(list.map(n => n.id))

    for (const n of list) {
      if (!seen.has(n.id)) {
        postNative('toast', { id: n.id, kind: n.kind, title: n.title, message: n.message, detail: n.detail })
      }
    }

    seen = next
  })

  registry.subscribe(() => postNative('contributionsChanged', {}))

  started = loadPlugins(options.plugins ?? []).then(plugins => {
    const result = { plugins, contributions: listContributions() }
    postNative('ready', result as unknown as Record<string, unknown>)

    return result
  })

  return started
}

function mount(target: MountTarget) {
  currentTarget = target

  if (target.kind === 'route') {
    const path = target.path.startsWith('/') ? target.path : `/${target.path}`
    mountedPath = path

    if (window.location.hash !== `#${path}`) {
      window.location.hash = `#${path}`
    }
  }

  rerender?.()
}

window.addEventListener('hashchange', () => {
  const path = window.location.hash.replace(/^#/, '') || '/'

  if (path === mountedPath) {
    return // our own mount(), not a plugin navigation
  }

  mountedPath = null
  // A plugin called host.navigate(...). Native may want to switch to another surface; the page
  // follows within the route surface on its own.
  postNative('navigate', { path })
})

async function addPlugin(plugin: PluginInput) {
  return (await loadPlugins([plugin]))[0]
}

function removePlugin(pluginId: string) {
  unloadRuntimePlugin(pluginId)
  loadedIds.delete(pluginId)
}

const api = {
  version: 1,
  start,
  mount,
  listContributions,
  listPlugins: () => Object.values($pluginRecords.get()),
  runPalette,
  setPluginEnabled: (pluginId: string, enabled: boolean) => setPluginEnabled(pluginId, enabled),
  addPlugin,
  removePlugin,
  gatewayState: () => $gatewayState.get(),
  /** Native answers a `requestId` message (pickOpenPath / pickSavePath). */
  resolveNative: settleNative,
  /** Debug: bridge members the Desktop code asked for that the host does not provide. */
  missingBridgeMembers,
  hasNative
}

declare global {
  interface Window {
    VibePluginHost: typeof api
  }
}

window.VibePluginHost = api
postNative('loaded', { version: api.version })
