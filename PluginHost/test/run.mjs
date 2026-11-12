// Headless Chromium check of the built bundle, loaded from file:// exactly like WKWebView would.
//
//   node test/run.mjs           # against the live backend (default http://127.0.0.1:9119)
//   node test/run.mjs --mock    # against test/mock-backend.mjs (empty data, token-checked)
//
// A fake `window.webkit.messageHandlers.vibe` is injected so the page runs in `native` transport
// mode: REST calls are posted out of the page and performed here in Node (the job the Swift side
// does), which also exercises the native message protocol. Outputs go to shots/.
//
// The session token is read from ~/.hermes/.env (HERMES_DASHBOARD_SESSION_TOKEN) or
// $HERMES_TOKEN and is never printed or written to disk.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { chromium } from 'playwright-core'

import { startMockBackend } from './mock-backend.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '..')
const shots = path.join(root, 'shots')
const lite = process.argv.includes('--lite')
const indexHtml = path.join(root, lite ? 'dist-lite/index.html' : 'dist/index.html')
const pluginsDir = process.env.HERMES_DESKTOP_PLUGINS_DIR || path.join(os.homedir(), '.hermes/desktop-plugins')
const PLUGINS = ['workflows', 'task-manager', 'deep-research', 'code-workflows']
const bearer = process.argv.includes('--bearer')
const mock = process.argv.includes('--mock') || bearer
const suffix = (bearer ? '-bearer' : mock ? '-mock' : '') + (lite ? '-lite' : '')

if (!fs.existsSync(indexHtml)) {
  console.error('dist/index.html missing - run `npm run build` first')
  process.exit(1)
}

fs.mkdirSync(shots, { recursive: true })

function readToken() {
  if (process.env.HERMES_TOKEN) {
    return process.env.HERMES_TOKEN
  }

  const envFile = path.join(os.homedir(), '.hermes/.env')
  const line = fs
    .readFileSync(envFile, 'utf8')
    .split('\n')
    .find(l => l.startsWith('HERMES_DASHBOARD_SESSION_TOKEN='))

  return line ? line.slice(line.indexOf('=') + 1).trim().replace(/^['"]|['"]$/g, '') : ''
}

const backend = mock ? await startMockBackend('mock-token', { auth: bearer ? 'bearer' : 'session-token' }) : null
const gatewayUrl = backend?.url ?? (process.env.HERMES_GATEWAY_URL || 'http://127.0.0.1:9119')
const token = backend ? 'mock-token' : readToken()
const redact = text => (token ? String(text).split(token).join('<token>') : String(text))

const plugins = PLUGINS.map(id => ({
  id,
  file: path.join(pluginsDir, id, 'plugin.js'),
  source: fs.readFileSync(path.join(pluginsDir, id, 'plugin.js'), 'utf8'),
  // code-workflows ships opt-in (defaultEnabled: false); force it on so its surfaces are listed too.
  ...(id === 'code-workflows' ? { enabled: true } : {})
}))

const executablePath = (() => {
  const base = path.join(os.homedir(), '.cache/ms-playwright')
  const dirs = fs.readdirSync(base).filter(d => /^chromium-\d+$/.test(d)).sort().reverse()

  for (const d of dirs) {
    const exe = path.join(base, d, 'chrome-linux64/chrome')

    if (fs.existsSync(exe)) {
      return exe
    }
  }

  return undefined
})()

const browser = await chromium.launch({ executablePath, headless: true })
const context = await browser.newContext({ viewport: { width: 1280, height: 820 }, colorScheme: 'dark' })
const page = await context.newPage()

const consoleLog = []
const pageErrors = []
const nativeMessages = []
const apiCalls = []

page.on('console', msg => consoleLog.push({ type: msg.type(), text: redact(msg.text()) }))
page.on('pageerror', err => pageErrors.push(redact(err.stack || err.message)))

// --- the "Swift side": receives every postMessage and answers `api` requests ---------------------
await page.exposeBinding('__vibeNativeBridge', async (_source, message) => {
  const { type, requestId, ...rest } = message || {}
  nativeMessages.push({ type, ...(type === 'api' ? { method: rest.method, url: redact(rest.url) } : redactObject(rest)) })

  if (type !== 'api') {
    return
  }

  let result

  try {
    const res = await fetch(rest.url, {
      method: rest.method,
      headers: rest.headers,
      body: rest.body,
      signal: AbortSignal.timeout(rest.timeoutMs || 15000)
    })
    result = { status: res.status, statusText: res.statusText, body: await res.text() }
  } catch (error) {
    result = { error: String(error?.message || error) }
  }

  apiCalls.push({ method: rest.method, path: new URL(rest.url).pathname, status: result.status ?? result.error })
  await page.evaluate(([id, value]) => window.VibePluginHost.resolveNative(id, value), [requestId, result]).catch(() => {})
})

function redactObject(obj) {
  return JSON.parse(redact(JSON.stringify(obj ?? {})))
}

await page.addInitScript(() => {
  window.webkit = { messageHandlers: { vibe: { postMessage: m => window.__vibeNativeBridge(m) } } }
})

const t0 = Date.now()
await page.goto(pathToFileURL(indexHtml).href)
await page.waitForFunction(() => Boolean(window.VibePluginHost), null, { timeout: 30_000 })
const bootMs = Date.now() - t0

const startResult = await page.evaluate(
  async ([gatewayUrl, token, plugins, auth]) => {
    const r = await window.VibePluginHost.start({ gatewayUrl, token, profile: 'default', plugins, auth })

    return r.plugins
  },
  [gatewayUrl, token, plugins, bearer ? 'bearer' : 'session-token']
)

const contributions = await page.evaluate(() => window.VibePluginHost.listContributions())
fs.writeFileSync(path.join(shots, `contributions${suffix}.json`), JSON.stringify(contributions, null, 2))

async function shoot(target, name, settleMs = 3500) {
  await page.evaluate(t => window.VibePluginHost.mount(t), target)
  await page.waitForTimeout(settleMs)
  const file = path.join(shots, `${name}${suffix}.png`)
  await page.screenshot({ path: file })
  const text = await page.evaluate(() => document.body.innerText.slice(0, 600))

  return { file, text: redact(text) }
}

const results = {}
results.workflows = await shoot({ kind: 'route', path: '/workflows' }, 'workflows')
results.tasks = await shoot({ kind: 'route', path: '/tasks' }, 'tasks')
results.research = await shoot({ kind: 'route', path: '/research' }, 'research')
results.codeWorkflows = await shoot({ kind: 'route', path: '/code-workflows' }, 'code-workflows')
results.workflowsPane = await shoot({ kind: 'pane', id: 'workflows:pane' }, 'workflows-pane', 2000)

const statusItem = contributions.statusBar[0]

if (statusItem) {
  await page.setViewportSize({ width: 420, height: 32 })
  results.status = await shoot({ kind: 'status', id: statusItem.id }, 'status', 2000)
  await page.setViewportSize({ width: 1280, height: 820 })
}

const gatewayState = await page.evaluate(() => window.VibePluginHost.gatewayState())
const missing = await page.evaluate(() => window.VibePluginHost.missingBridgeMembers())

const report = {
  mode: (bearer ? 'mock-bearer' : mock ? 'mock' : 'live') + (lite ? ' (lite build)' : ''),
  gatewayUrl,
  bootMs,
  gatewayState,
  plugins: startResult,
  pageErrors,
  consoleErrors: consoleLog.filter(m => m.type === 'error'),
  consoleWarnings: consoleLog.filter(m => m.type === 'warning').slice(0, 40),
  apiCalls: summarize(apiCalls),
  nativeMessages: summarize(nativeMessages.filter(m => m.type !== 'api').map(m => m.type)),
  missingBridgeMembers: missing,
  surfaces: results
}

function summarize(list) {
  const counts = {}

  for (const item of list) {
    const key = typeof item === 'string' ? item : `${item.method} ${item.path} -> ${item.status}`
    counts[key] = (counts[key] || 0) + 1
  }

  return counts
}

fs.writeFileSync(path.join(shots, `report${suffix}.json`), JSON.stringify(report, null, 2))
fs.writeFileSync(path.join(shots, `console${suffix}.log`), consoleLog.map(m => `[${m.type}] ${m.text}`).join('\n'))

console.log(JSON.stringify({ ...report, consoleWarnings: report.consoleWarnings.length, surfaces: Object.keys(results) }, null, 2))

await browser.close()
await backend?.close()
process.exit(pageErrors.length ? 1 : 0)
