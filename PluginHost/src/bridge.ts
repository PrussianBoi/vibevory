/**
 * Fake `window.hermesDesktop` bridge for running Hermes Desktop plugins outside Electron.
 *
 * The real bridge (apps/desktop/electron/preload.ts) is ~150 IPC doors into the Electron main
 * process. Plugin surfaces only reach a handful of them:
 *   - `api` / `getConnection*` / `getGatewayWsUrl*`  -> REST + WebSocket to the gateway (done here
 *     with fetch / WebSocket and the token given to `VibePluginHost.start`)
 *   - `openExternal`, `notify`, `writeClipboard`, `revealPath`, `selectPaths`, `selectSavePath`
 *     -> native-only, forwarded to the WKWebView host via
 *        `window.webkit.messageHandlers.vibe.postMessage({ type, ... })`
 *   - `profile.*` -> answered from the start options.
 *
 * Every other member resolves through a Proxy: `on*` subscriptions return a no-op disposer,
 * everything else is `undefined` (= "feature absent"), which the Desktop code already treats as
 * an older shell. This module must be imported FIRST so it exists before any Desktop module
 * evaluates.
 */

export interface HostConfig {
  gatewayUrl: string
  token: string
  profile: string
  /** `native`: REST goes through the WKWebView host (no CORS from file://). `fetch`: direct. */
  transport: 'fetch' | 'native'
  /** `session-token`: X-Hermes-Session-Token + `?token=` on /api/ws (loopback / Desktop-owned
   *  backends). `bearer`: Authorization: Bearer <OAuth access token> + a single-use ticket minted
   *  per WebSocket dial (OAuth-gated dashboards). */
  auth: 'bearer' | 'session-token'
}

type Pending = { resolve: (value: unknown) => void; timer: ReturnType<typeof setTimeout> }

let config: HostConfig | null = null
let configReady: (cfg: HostConfig) => void = () => {}
const configPromise = new Promise<HostConfig>(resolve => {
  configReady = resolve
})

export function setHostConfig(cfg: HostConfig) {
  config = { ...cfg, gatewayUrl: cfg.gatewayUrl.replace(/\/+$/, '') }
  configReady(config)
}

export const hostConfig = () => config
const ready = () => (config ? Promise.resolve(config) : configPromise)

// ---- native channel ---------------------------------------------------------------------------

interface WebkitWindow {
  webkit?: { messageHandlers?: { vibe?: { postMessage: (message: unknown) => void } } }
}

const nativeHandler = () => (window as unknown as WebkitWindow).webkit?.messageHandlers?.vibe

export const hasNative = () => Boolean(nativeHandler())

/** Fire-and-forget message to the Swift side. No-op outside a WKWebView. */
export function postNative(type: string, payload: Record<string, unknown> = {}): boolean {
  const handler = nativeHandler()

  if (!handler) {
    return false
  }

  try {
    handler.postMessage({ type, ...payload })

    return true
  } catch (error) {
    console.warn('[vibe] postMessage failed', error)

    return false
  }
}

const pending = new Map<string, Pending>()
let nextRequestId = 1

/** Request/response to the Swift side: posts `{ type, requestId, ... }`; native answers with
 *  `window.VibePluginHost.resolveNative(requestId, result)`. Resolves `fallback` without a
 *  native host or after `timeoutMs` (pickers get no timeout). */
export function requestNative<T>(
  type: string,
  payload: Record<string, unknown>,
  fallback: T,
  timeoutMs = 0
): Promise<T> {
  if (!hasNative()) {
    return Promise.resolve(fallback)
  }

  const requestId = `r${nextRequestId++}`

  return new Promise<T>(resolve => {
    const timer = timeoutMs > 0 ? setTimeout(() => settleNative(requestId, fallback), timeoutMs) : (0 as never)
    pending.set(requestId, { resolve: resolve as (value: unknown) => void, timer })

    if (!postNative(type, { ...payload, requestId })) {
      settleNative(requestId, fallback)
    }
  })
}

export function settleNative(requestId: string, result: unknown): boolean {
  const entry = pending.get(requestId)

  if (!entry) {
    return false
  }

  pending.delete(requestId)
  clearTimeout(entry.timer)
  entry.resolve(result)

  return true
}

// ---- REST -------------------------------------------------------------------------------------

interface ApiRequest {
  path: string
  method?: string
  body?: unknown
  upload?: { filename: string; contentType?: string; bytes: ArrayBuffer }
  timeoutMs?: number
  profile?: null | string
}

const DEFAULT_TIMEOUT_MS = 15_000

const authHeaders = (cfg: HostConfig): Record<string, string> =>
  cfg.auth === 'bearer' ? { Authorization: `Bearer ${cfg.token}` } : { 'X-Hermes-Session-Token': cfg.token }

/** Raw HTTP result, from fetch or from the native host. */
interface RawResponse {
  status: number
  body: string
  statusText?: string
}

const bytesToBase64 = (bytes: ArrayBuffer) => {
  let binary = ''
  const view = new Uint8Array(bytes)

  for (let i = 0; i < view.length; i += 0x8000) {
    binary += String.fromCharCode(...view.subarray(i, i + 0x8000))
  }

  return btoa(binary)
}

async function sendViaFetch(cfg: HostConfig, request: ApiRequest, method: string, timeoutMs: number): Promise<RawResponse> {
  const headers = authHeaders(cfg)
  let body: BodyInit | undefined

  if (request.upload) {
    const form = new FormData()
    form.append(
      'file',
      new Blob([request.upload.bytes], { type: request.upload.contentType || 'application/octet-stream' }),
      request.upload.filename
    )
    body = form
  } else if (request.body !== undefined && method !== 'GET' && method !== 'HEAD') {
    headers['Content-Type'] = 'application/json'
    body = JSON.stringify(request.body)
  }

  const controller = new AbortController()
  const timer = timeoutMs > 0 ? setTimeout(() => controller.abort(), timeoutMs) : undefined

  try {
    const response = await fetch(`${cfg.gatewayUrl}${request.path}`, { method, headers, body, signal: controller.signal })

    return { status: response.status, statusText: response.statusText, body: await response.text() }
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`Timed out connecting to Hermes backend after ${timeoutMs}ms`)
    }

    throw error instanceof Error ? error : new Error(String(error))
  } finally {
    clearTimeout(timer)
  }
}

/** Native transport. Posts `{ type: 'api', requestId, url, method, headers, body?, bodyBase64?,
 *  uploadFilename?, uploadContentType?, timeoutMs }`; the host answers
 *  `VibePluginHost.resolveNative(requestId, { status, body })` or `{ error }`. */
async function sendViaNative(cfg: HostConfig, request: ApiRequest, method: string, timeoutMs: number): Promise<RawResponse> {
  const headers = authHeaders(cfg)
  const message: Record<string, unknown> = { url: `${cfg.gatewayUrl}${request.path}`, method, headers, timeoutMs }

  if (request.upload) {
    message.bodyBase64 = bytesToBase64(request.upload.bytes)
    message.uploadFilename = request.upload.filename
    message.uploadContentType = request.upload.contentType || 'application/octet-stream'
  } else if (request.body !== undefined && method !== 'GET' && method !== 'HEAD') {
    headers['Content-Type'] = 'application/json'
    message.body = JSON.stringify(request.body)
  }

  const timedOut = { error: `Timed out connecting to Hermes backend after ${timeoutMs}ms` }
  // A little slack over the native timeout so the host's own timeout answer wins.
  const result = await requestNative<{ status?: number; body?: string; error?: string; statusText?: string }>(
    'api',
    message,
    hasNative() ? timedOut : { error: 'Native host unavailable' },
    timeoutMs > 0 ? timeoutMs + 2_000 : 0
  ).then(value => value ?? timedOut)

  if (result.error || typeof result.status !== 'number') {
    throw new Error(result.error || 'Native host returned no status')
  }

  return { status: result.status, body: result.body ?? '', statusText: result.statusText }
}

/** Mirrors Electron main's fetchJson: JSON in/out, session-token header, and an
 *  `Error("<status>: <body>")` with `.statusCode` on HTTP failure (plugins parse that prefix). */
export async function api<T>(request: ApiRequest): Promise<T> {
  const cfg = await ready()
  const method = (request.method || 'GET').toUpperCase()
  const timeoutMs = request.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const response =
    cfg.transport === 'native'
      ? await sendViaNative(cfg, request, method, timeoutMs)
      : await sendViaFetch(cfg, request, method, timeoutMs)

  if (response.status >= 400) {
    const error = new Error(`${response.status}: ${response.body || response.statusText || ''}`) as Error & {
      statusCode?: number
    }
    error.statusCode = response.status
    throw error
  }

  if (!response.body) {
    return null as T
  }

  try {
    return JSON.parse(response.body) as T
  } catch {
    throw new Error(`Invalid JSON from ${request.path} (status ${response.status}): ${response.body.slice(0, 200)}`)
  }
}

// ---- connection descriptors -------------------------------------------------------------------

const wsBase = (url: string) => url.replace(/^http/, 'ws')

async function connection() {
  const cfg = await ready()

  return {
    baseUrl: cfg.gatewayUrl,
    token: cfg.token,
    wsUrl: `${wsBase(cfg.gatewayUrl)}/api/ws?token=${encodeURIComponent(cfg.token)}`,
    // An OAuth-gated backend gets 'oauth': plugin sockets then stay on their polling fallback,
    // exactly as the Desktop does for OAuth remotes.
    authMode: cfg.auth === 'bearer' ? ('oauth' as const) : ('token' as const),
    mode: 'local' as const,
    source: 'settings' as const,
    isFullscreen: false,
    nativeOverlayWidth: 0,
    logs: [] as string[]
  }
}

/** The URL for one gateway WebSocket dial. Bearer auth mints a fresh single-use ticket each time. */
export async function gatewayWsUrl(): Promise<string> {
  const cfg = await ready()

  if (cfg.auth !== 'bearer') {
    return (await connection()).wsUrl
  }

  const { ticket } = await api<{ ticket: string }>({ path: '/api/auth/ws-ticket', method: 'POST', body: {} })

  return `${wsBase(cfg.gatewayUrl)}/api/ws?ticket=${encodeURIComponent(ticket)}`
}

// ---- the bridge -------------------------------------------------------------------------------

const noopDisposer = () => () => {}

const profileRoute = async () => ({ profile: (await ready()).profile })

const explicit: Record<string, unknown> = {
  glassSupported: false,
  translucencySupported: false,
  localModelsEnabled: false,
  assumeFreshInstall: false,
  localSkin: null,

  getConnection: () => connection(),
  getConnectionFor: () => connection(),
  getGatewayWsUrl: () => gatewayWsUrl(),
  getGatewayWsUrlFor: () => gatewayWsUrl(),
  // Token-mode descriptors never ask for a minted plugin socket URL; null = stay on polling.
  getPluginWsUrl: async () => null,
  revalidateConnection: async () => ({ ok: true, rebuilt: false }),
  getProfileRoutes: async (profiles: string[]) => profiles.map(profile => ({ profile })),

  api,

  profile: {
    get: async () => ({ profile: (await ready()).profile, name: (await ready()).profile }),
    getDefault: profileRoute,
    setDefault: async (route: unknown) => route,
    onDefaultChanged: noopDisposer,
    remember: async (name: null | string) => ({ profile: name, name }),
    set: async (name: null | string) => ({ profile: name, name })
  },

  // Native-only doors -> WKWebView host.
  openExternal: async (url: string) => {
    if (!postNative('openExternal', { url })) {
      window.open(url, '_blank', 'noopener')
    }
  },
  notify: async (payload: unknown) => postNative('notify', { payload }),
  writeClipboard: async (text: string) => {
    if (postNative('clipboard.write', { text })) {
      return true
    }

    try {
      await navigator.clipboard.writeText(text)

      return true
    } catch {
      return false
    }
  },
  readClipboard: async () => {
    try {
      return await navigator.clipboard.readText()
    } catch {
      return ''
    }
  },
  revealPath: async (path: string) => postNative('revealPath', { path }),
  selectPaths: (options?: Record<string, unknown>) => requestNative<string[]>('pickOpenPath', { options }, []),
  selectSavePath: (options?: Record<string, unknown>) => requestNative<null | string>('pickSavePath', { options }, null),
  openSessionWindow: async (sessionId: string, opts?: unknown) => ({
    ok: postNative('openSession', { sessionId, opts }),
    error: hasNative() ? undefined : 'not available in the plugin host'
  }),

  // Appearance pushes from the Desktop theme engine; harmless here.
  setTitleBarTheme: () => {},
  setNativeTheme: () => {},
  setTranslucency: () => {},
  setActiveWork: () => {},
  setKeepAwake: () => {},
  setActiveConnectionRoute: () => {},
  reportRendererError: () => {},
  logLine: () => {},
  getVersion: async () => 'vibevory-pluginhost',
  getOnBattery: async () => false,
  claimAmbientCue: async () => false,
  windowControls: { custom: false, minimize() {}, toggleMaximize() {}, close() {} }
}

const missing = new Set<string>()

export const fakeBridge = new Proxy(explicit, {
  get(target, key) {
    if (typeof key !== 'string') {
      return undefined
    }

    if (key in target) {
      return target[key]
    }

    // Event subscriptions: hand back a disposer so `bridge.onX?.(cb)()` patterns stay safe.
    if (/^on[A-Z]/.test(key)) {
      return noopDisposer
    }

    if (!missing.has(key)) {
      missing.add(key)
      console.debug(`[vibe] hermesDesktop.${key} is not provided by the plugin host`)
    }

    return undefined
  },
  has(target, key) {
    return key in target
  }
})

export const missingBridgeMembers = () => [...missing]

;(window as unknown as { hermesDesktop: unknown }).hermesDesktop = fakeBridge
