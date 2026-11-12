/**
 * Workflows for Hermes Desktop: live progress and controls for dynamic workflow runs.
 * Plain ESM for the unified-package loader: no build step, no JSX, SDK imports only.
 *
 * Data comes from /api/plugins/workflows (ctx.rest, ambient profile). Runs start from a conversation
 * (the `workflow` tool), so this page watches and controls them: stop, pause, resume.
 */

import { Badge, Button, Codicon, EmptyState, host, PALETTE_AREA, ROUTES_AREA, SIDEBAR_NAV_AREA, useMutation, useQuery, useQueryClient, useValue } from '@hermes/plugin-sdk'
import { useEffect, useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'

const ID = 'workflows'
const ROUTE = '/workflows'
const ACTIVE = new Set(['starting', 'running', 'paused', 'stopping'])
const DONE = new Set(['done', 'cached'])
let pluginContext = null

const muted = 'text-(--ui-text-tertiary)'
const card = 'rounded-[4px] border border-(--ui-stroke-secondary) p-3'
const mono = 'font-mono text-[0.75rem] leading-[1.35] whitespace-pre'

function rest(path, options) {
  if (!pluginContext) throw new Error('Workflows plugin is not registered')
  return pluginContext.rest(path, options)
}

function useProfile() {
  return String(useValue(host.state.profile) || '').trim() || 'default'
}

function useLive(key, path, fast) {
  const profile = useProfile()
  return useQuery({
    queryKey: [ID, profile, ...key],
    queryFn: () => rest(path),
    refetchInterval: (query) => (fast(query?.state?.data) ? 1500 : 8000)
  })
}

function fmtDuration(seconds) {
  const s = Math.max(0, Math.floor(seconds || 0))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`
  return `${Math.floor(s / 3600)}h${String(Math.floor((s % 3600) / 60)).padStart(2, '0')}m`
}

function fmtTokens(n) {
  n = Number(n || 0)
  if (n < 1000) return String(n)
  if (n < 1e6) return `${(n / 1000).toFixed(n >= 1e4 ? 0 : 1)}k`
  return `${(n / 1e6).toFixed(1)}M`
}

function statusVariant(status) {
  if (status === 'completed') return 'secondary'
  if (status === 'failed' || status === 'interrupted') return 'destructive'
  if (status === 'paused' || status === 'stopped' || status === 'stopping') return 'outline'
  return 'default'
}

function useControl() {
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: ({ id, action }) => rest(`/runs/${encodeURIComponent(id)}/control`, { method: 'POST', body: { action } }),
    onSuccess: (data, vars) => host.notify({ kind: 'success', message: `${vars.action} ${data?.outcome === 'requested' ? 'requested' : 'done'}` }),
    onError: (error) => host.notify({ kind: 'error', message: String(error?.message || error) }),
    onSettled: () => queryClient.invalidateQueries({ queryKey: [ID] })
  })
  return { busy: mutation.isPending, run: (id, action) => mutation.mutate({ id, action }) }
}

function ProgressBar({ done, lost, total }) {
  const pct = total ? Math.round((100 * done) / total) : 0
  const lostPct = total ? Math.round((100 * lost) / total) : 0
  return jsxs('div', {
    className: 'flex h-1.5 w-full overflow-hidden rounded-full bg-(--ui-stroke-secondary)',
    children: [
      jsx('div', { className: 'h-full bg-(--ui-accent-primary,#3b82f6)', style: { width: `${pct}%` } }),
      jsx('div', { className: 'h-full bg-(--ui-danger,#ef4444)', style: { width: `${lostPct}%` } })
    ]
  })
}

function RunRow({ run, selected, onSelect }) {
  const t = run.totals || {}
  return jsxs('button', {
    type: 'button',
    onClick: () => onSelect(run.id),
    className: `flex w-full flex-col gap-1 rounded-[4px] px-2 py-1.5 text-left hover:bg-(--ui-bg-hover) ${selected ? 'bg-(--ui-bg-selected)' : ''}`,
    children: [
      jsxs('div', {
        className: 'flex items-center gap-2',
        children: [
          jsx('span', { className: 'min-w-0 flex-1 truncate text-[0.8125rem] font-medium', children: run.name || run.id }),
          jsx(Badge, { variant: statusVariant(run.status), children: run.status })
        ]
      }),
      jsx(ProgressBar, { done: t.done || 0, lost: t.lost || 0, total: t.agents || 0 }),
      jsx('div', {
        className: `text-[0.6875rem] ${muted}`,
        children: `${t.done || 0}/${t.agents || 0} agents · ${fmtTokens(t.tokens)} tok · ${fmtDuration(run.elapsed)}${run.origin ? ' · ' + run.origin : ''}`
      })
    ]
  })
}

function PhaseRow({ phase }) {
  return jsxs('div', {
    className: 'flex items-center gap-3',
    children: [
      jsx('span', { className: 'w-4 text-center', children: phase.icon }),
      jsx('span', { className: 'w-40 truncate text-[0.8125rem]', children: phase.label }),
      jsx('div', { className: 'flex-1', children: jsx(ProgressBar, { done: phase.done, lost: phase.lost, total: phase.total }) }),
      jsx('span', { className: `w-20 text-right text-[0.75rem] ${muted}`, children: phase.total ? `${phase.done}/${phase.total}${phase.lost ? ' · ' + phase.lost + '✗' : ''}` : '—' })
    ]
  })
}

function AgentRow({ agent, now }) {
  const [open, setOpen] = useState(false)
  const running = agent.status === 'running'
  const took = agent.started_at ? (agent.ended_at || now) - agent.started_at : 0
  const icon = DONE.has(agent.status) ? '✔' : agent.status === 'failed' ? '✗' : agent.status === 'stopped' ? '■' : running ? '◐' : '○'
  return jsxs('div', {
    className: 'border-b border-(--ui-stroke-secondary) py-1.5 last:border-b-0',
    children: [
      jsxs('button', {
        type: 'button',
        className: 'flex w-full items-center gap-2 text-left',
        onClick: () => setOpen(!open),
        children: [
          jsx('span', { className: 'w-4 text-center', children: icon }),
          jsx('span', { className: `w-8 text-[0.6875rem] ${muted}`, children: `#${agent.n}` }),
          jsx('span', { className: 'min-w-0 flex-1 truncate text-[0.8125rem]', children: agent.label }),
          agent.status === 'cached' ? jsx(Badge, { variant: 'outline', children: 'cached' }) : null,
          agent.options?.light ? jsx(Badge, { variant: 'outline', children: 'light' }) : null,
          agent.attempt > 1 ? jsx(Badge, { variant: 'outline', children: `retry ${agent.attempt - 1}` }) : null,
          jsx('span', { className: `w-36 truncate text-right text-[0.6875rem] ${muted}`, children: running && agent.tools?.length ? agent.tools[agent.tools.length - 1] : agent.model || '' }),
          jsx('span', { className: `w-24 text-right text-[0.6875rem] ${muted}`, children: `${fmtDuration(took)} · ${fmtTokens(agent.tokens)}` })
        ]
      }),
      open
        ? jsxs('div', {
            className: 'mt-1.5 flex flex-col gap-1.5 pl-14 text-[0.75rem]',
            children: [
              agent.phase ? jsx('div', { className: muted, children: `Phase: ${agent.phase}${agent.group ? ' · ' + agent.group : ''}` }) : null,
              jsx('div', { className: `${muted}`, children: 'Prompt' }),
              jsx('div', { className: 'whitespace-pre-wrap break-words', children: agent.prompt }),
              agent.tools?.length ? jsx('div', { className: muted, children: `Tools: ${agent.tools.join(' → ')}` }) : null,
              agent.error ? jsx('div', { className: 'text-(--ui-danger,#ef4444)', children: agent.error }) : null,
              agent.preview ? jsxs('div', { children: [jsx('span', { className: muted, children: 'Result: ' }), agent.preview] }) : null,
              agent.worktree ? jsx('div', { className: muted, children: `Worktree: ${agent.worktree}` }) : null
            ]
          })
        : null
    ]
  })
}

function RunDetail({ runId }) {
  const detail = useLive(['run', runId], `/runs/${encodeURIComponent(runId)}`, (d) => d && ACTIVE.has(d.status))
  const control = useControl()
  const [filter, setFilter] = useState('all')
  const [now, setNow] = useState(Date.now() / 1000)
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now() / 1000), 1000)
    return () => clearInterval(t)
  }, [])
  if (detail.isLoading) return jsx(EmptyState, { title: 'Loading…' })
  if (detail.error) return jsx(EmptyState, { title: 'Run unavailable', description: String(detail.error?.message || detail.error) })
  const d = detail.data
  const state = d.state || {}
  const active = ACTIVE.has(d.status)
  const agents = (state.agents || []).filter((a) =>
    filter === 'all' ? true : filter === 'running' ? a.status === 'running' || a.status === 'queued' : filter === 'failed' ? a.status === 'failed' || a.status === 'stopped' : DONE.has(a.status))
  const logs = (state.logs || []).slice(-8).reverse()
  const result = d.result && d.result.value !== undefined ? d.result.value : null
  return jsxs('div', {
    className: 'flex flex-col gap-4 p-5',
    children: [
      jsxs('div', {
        className: 'flex items-start gap-3',
        children: [
          jsxs('div', {
            className: 'min-w-0 flex-1',
            children: [
              jsxs('div', {
                className: 'flex items-center gap-2',
                children: [
                  jsx('h2', { className: 'truncate text-[1rem] font-semibold', children: d.name }),
                  jsx(Badge, { variant: statusVariant(d.status), children: d.status })
                ]
              }),
              jsx('div', { className: `text-[0.75rem] ${muted}`, children: d.description }),
              jsx('div', {
                className: `mt-1 text-[0.75rem] ${muted}`,
                children: `${d.totals.done}/${d.totals.agents} agents · ${d.totals.running} running · ${fmtTokens(d.totals.tokens)} tokens · ${fmtDuration(active && state.started_at ? now - state.started_at : d.elapsed)} · ${d.id}`
              })
            ]
          }),
          active && d.status !== 'paused'
            ? jsx(Button, { size: 'sm', variant: 'secondary', disabled: control.busy, onClick: () => control.run(d.id, 'pause'), children: 'Pause' })
            : null,
          d.status === 'paused' ? jsx(Button, { size: 'sm', variant: 'secondary', disabled: control.busy, onClick: () => control.run(d.id, 'resume'), children: 'Resume' }) : null,
          active ? jsx(Button, { size: 'sm', variant: 'destructive', disabled: control.busy || d.status === 'stopping', onClick: () => control.run(d.id, 'stop'), children: 'Stop' }) : null
        ]
      }),
      jsx('div', { className: `${card} flex flex-col gap-2`, children: (d.phases || []).map((p, i) => jsx(PhaseRow, { phase: p }, `${p.group}|${p.title}|${i}`)) }),
      logs.length
        ? jsx('div', {
            className: `${card} flex flex-col gap-0.5 text-[0.75rem]`,
            children: logs.map((l, i) => jsx('div', { className: l.level === 'warn' ? 'text-(--ui-warning,#d97706)' : '', children: `${l.level === 'warn' ? '!' : '›'} ${l.message}` }, i))
          })
        : null,
      state.error ? jsx('div', { className: `${card} text-[0.8125rem] text-(--ui-danger,#ef4444)`, children: state.error }) : null,
      jsxs('div', {
        className: card,
        children: [
          jsxs('div', {
            className: 'mb-2 flex items-center gap-2',
            children: [
              jsx('span', { className: 'flex-1 text-[0.8125rem] font-medium', children: `Agents (${(state.agents || []).length})` }),
              ...['all', 'running', 'done', 'failed'].map((f) =>
                jsx(Button, { key: f, size: 'sm', variant: filter === f ? 'secondary' : 'ghost', onClick: () => setFilter(f), children: f }))
            ]
          }),
          agents.length ? jsx('div', { children: agents.slice(-300).map((a) => jsx(AgentRow, { agent: a, now }, a.n)) }) : jsx('div', { className: `text-[0.75rem] ${muted}`, children: 'No agents in this view.' })
        ]
      }),
      !active && result !== null
        ? jsxs('div', {
            className: card,
            children: [
              jsx('div', { className: 'mb-1 text-[0.8125rem] font-medium', children: 'Result' }),
              jsx('pre', { className: `${mono} max-h-[420px] overflow-auto whitespace-pre-wrap break-words`, children: typeof result === 'string' ? result : JSON.stringify(result, null, 2) })
            ]
          })
        : null,
      jsx('div', { className: `text-[0.6875rem] ${muted}`, children: `Script: ${state.script_path || ''}${!active ? ` · Save it as a command from chat: /workflows save ${d.id} <name>` : ''}` })
    ]
  })
}

function Page() {
  const runs = useLive(['runs'], '/runs?limit=40', (d) => (d?.runs || []).some((r) => ACTIVE.has(r.status)))
  const [selected, setSelected] = useState(() => pluginContext?.storage?.get?.('run', null) || null)
  const rows = runs.data?.runs || []
  useEffect(() => {
    if (!selected && rows.length) setSelected(rows[0].id)
  }, [rows.length])
  const select = (id) => {
    setSelected(id)
    try { pluginContext?.storage?.set?.('run', id) } catch {}
  }
  return jsxs('div', {
    className: 'flex h-full min-h-0',
    children: [
      jsxs('aside', {
        className: 'flex w-72 shrink-0 flex-col gap-1 overflow-y-auto border-r border-(--ui-stroke-secondary) p-2',
        children: [
          jsxs('div', {
            className: 'flex items-center gap-2 px-2 py-1',
            children: [jsx(Codicon, { name: 'run-all' }), jsx('span', { className: 'text-[0.875rem] font-semibold', children: 'Workflows' })]
          }),
          runs.isLoading
            ? jsx(EmptyState, { title: 'Loading…' })
            : runs.error
              ? jsx(EmptyState, { title: 'Workflows unavailable', description: String(runs.error?.message || runs.error) })
              : rows.length
                ? rows.map((r) => jsx(RunRow, { run: r, selected: r.id === selected, onSelect: select }, r.id))
                : jsx(EmptyState, { title: 'No runs yet', description: 'Ask Hermes to "use a workflow" for a task, or say ultracode.' })
        ]
      }),
      jsx('main', {
        className: 'min-w-0 flex-1 overflow-y-auto',
        children: selected ? jsx(RunDetail, { runId: selected }) : jsx(EmptyState, { title: 'Select a run' })
      })
    ]
  })
}

function Pane() {
  const runs = useLive(['runs', 'pane'], '/runs?limit=6', (d) => (d?.runs || []).some((r) => ACTIVE.has(r.status)))
  const rows = runs.data?.runs || []
  const active = rows.filter((r) => ACTIVE.has(r.status))
  const shown = active.length ? active : rows.slice(0, 2)
  return jsxs('div', {
    className: 'flex h-full flex-col gap-2 overflow-y-auto p-3',
    children: [
      jsx('div', { className: 'text-[0.75rem] font-medium', children: active.length ? `Workflows · ${active.length} running` : 'Workflows' }),
      shown.length
        ? shown.map((r) =>
            jsx('button', {
              type: 'button',
              className: `${card} text-left hover:bg-(--ui-bg-hover)`,
              onClick: () => { try { pluginContext?.storage?.set?.('run', r.id) } catch {} host.navigate(ROUTE) },
              children: jsx('pre', { className: mono, children: r.ascii })
            }, r.id))
        : jsx(EmptyState, { title: 'No workflow runs' })
    ]
  })
}

export default {
  id: ID,
  name: 'Workflows',
  register(ctx) {
    pluginContext = ctx
    ctx.registerMany([
      { id: 'page', area: ROUTES_AREA, data: { path: ROUTE }, render: () => jsx(Page, {}) },
      { id: 'nav', area: SIDEBAR_NAV_AREA, order: 45, data: { path: ROUTE, label: 'Workflows', codicon: 'run-all' } },
      {
        id: 'pane',
        area: 'panes',
        title: 'workflows',
        data: { placement: 'right', dock: { pane: 'workspace', pos: 'right' }, width: '300px' },
        render: () => jsx(Pane, {})
      },
      {
        id: 'open',
        area: PALETTE_AREA,
        data: { id: 'workflows.open', label: 'Workflows: Open', keywords: ['workflow', 'agents', 'progress', 'ultracode'], run: () => host.navigate(ROUTE) }
      }
    ])
  }
}
