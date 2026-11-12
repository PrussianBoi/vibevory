// A tiny Hermes Desktop plugin for the CI screenshots: a sidebar entry and a page.
import { Button, EmptyState, host, ROUTES_AREA, SIDEBAR_NAV_AREA } from '@hermes/plugin-sdk'
import { jsx, jsxs } from 'react/jsx-runtime'

function HelloPage() {
  return jsxs('div', {
    className: 'flex h-full flex-col items-center justify-center gap-4 p-8',
    children: [
      jsx(EmptyState, { title: 'Hello from a Desktop plugin', description: 'Loaded by the Desktop plugin SDK inside VibeVory.' }),
      jsx(Button, { onClick: () => host.notify({ kind: 'info', message: 'Plugin button works.' }), children: 'Say hi' })
    ]
  })
}

export default {
  id: 'hello',
  name: 'Hello',
  defaultEnabled: true,
  register(ctx) {
    ctx.registerMany([
      { id: 'page', area: ROUTES_AREA, data: { path: '/hello' }, render: () => jsx(HelloPage, {}) },
      { id: 'nav', area: SIDEBAR_NAV_AREA, order: 10, data: { path: '/hello', label: 'Hello', codicon: 'rocket' } }
    ])
  }
}
