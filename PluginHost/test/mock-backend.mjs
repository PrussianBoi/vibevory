// Minimal stand-in for a Hermes dashboard backend: token-checked REST + JSON-RPC WebSocket.
// Returns empty data for the plugin namespaces the four installed plugins read, so their pages
// render empty states. Read-only; never touches the real install.

import http from 'node:http'

import { WebSocketServer } from 'ws'

const EMPTY = {
  '/api/plugins/workflows/runs': { runs: [] },
  '/api/plugins/task-manager/summary': {
    domains: [{ id: 'dom_inbox', name: 'Inbox' }],
    counts: {},
    today: [],
    overdue: []
  },
  '/api/plugins/task-manager/tasks': { tasks: [], total: 0 },
  '/api/plugins/task-manager/health': { ok: true },
  '/api/status': { version: 'mock', gateway_running: true }
}

// `auth: 'session-token'` checks X-Hermes-Session-Token / ?token=; `auth: 'bearer'` mimics an
// OAuth-gated dashboard: Authorization: Bearer for REST, single-use ?ticket= for /api/ws.
export async function startMockBackend(token, { auth = 'session-token' } = {}) {
  const log = []
  const tickets = new Set()
  let nextTicket = 1
  const restOk = req =>
    auth === 'bearer' ? req.headers.authorization === `Bearer ${token}` : req.headers['x-hermes-session-token'] === token
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x')
    log.push(`${req.method} ${url.pathname}`)
    res.setHeader('Access-Control-Allow-Origin', '*')
    res.setHeader('Access-Control-Allow-Headers', '*')
    res.setHeader('Access-Control-Allow-Methods', '*')

    if (req.method === 'OPTIONS') {
      res.writeHead(204).end()

      return
    }

    if (url.pathname !== '/api/status' && !restOk(req)) {
      res.writeHead(401, { 'Content-Type': 'application/json' }).end('{"error":"unauthenticated"}')

      return
    }

    if (auth === 'bearer' && req.method === 'POST' && url.pathname === '/api/auth/ws-ticket') {
      const ticket = `t${nextTicket++}`
      tickets.add(ticket)
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ ticket, ttl_seconds: 30 }))

      return
    }

    const body = EMPTY[url.pathname] ?? (url.pathname.startsWith('/api/plugins/') ? {} : null)

    if (body === null) {
      res.writeHead(404, { 'Content-Type': 'application/json' }).end('{"detail":"Not Found"}')

      return
    }

    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(body))
  })

  const wss = new WebSocketServer({ noServer: true })
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url, 'http://x')

    const ticket = url.searchParams.get('ticket')
    const wsOk = auth === 'bearer' ? tickets.delete(ticket) : url.searchParams.get('token') === token

    if (url.pathname !== '/api/ws' || !wsOk) {
      socket.destroy()

      return
    }

    wss.handleUpgrade(req, socket, head, ws => {
      ws.on('message', raw => {
        let msg
        try {
          msg = JSON.parse(String(raw))
        } catch {
          return
        }
        if (msg && msg.id !== undefined && msg.method) {
          log.push(`rpc ${msg.method}`)
          ws.send(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }))
        }
      })
    })
  })

  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address()

  return {
    url: `http://127.0.0.1:${port}`,
    log,
    close: () => new Promise(resolve => {
      wss.clients.forEach(c => c.terminate())
      server.close(resolve)
    })
  }
}
