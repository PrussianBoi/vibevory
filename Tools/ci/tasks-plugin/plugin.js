/**
 * Tasks: the daily queue (recurring primary actions with a daily target, the engine) and the
 * execution queue (one-off work that carries over until done), tied to Dev's goal ladders.
 * Plain ESM for the Hermes desktop plugin loader; no build step or JSX.
 * Data: /api/plugins/task-manager (ctx.rest). Ladders are read from Vakra's life/ladders.md.
 */

import {
  Badge,
  Button,
  Codicon,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  EmptyState,
  host,
  Input,
  PALETTE_AREA,
  ROUTES_AREA,
  SegmentedControl,
  SIDEBAR_NAV_AREA,
  STATUSBAR_AREAS,
  Textarea,
  Tip,
  useMutation,
  useQuery,
  useQueryClient,
  useValue
} from '@hermes/plugin-sdk'
import { useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'

const ID = 'task-manager'
const ROUTE = '/tasks'
const DEFAULT_TAB = 'today'
const GREEN = '#5ad98c'
const AMBER = '#ffc066'
let pluginContext = null

const muted = 'text-(--ui-text-tertiary)'
const secondary = 'text-(--ui-text-secondary)'
const card = 'rounded-xl border border-(--ui-stroke-secondary) p-4 flex flex-col gap-3'
const fieldLabel = 'text-[0.65rem] font-medium uppercase tracking-wide text-(--ui-text-quaternary)'

function rest(path, options) {
  if (!pluginContext) throw new Error('Tasks plugin is not registered')
  return pluginContext.rest(path, options)
}

const valueOf = e => (e && e.target && e.target.value !== undefined ? e.target.value : e && e.value !== undefined ? e.value : e)

function localISO() {
  const d = new Date()
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset())
  return d.toISOString().slice(0, 10)
}

function longDate(iso) {
  const [y, m, d] = iso.split('-').map(Number)
  const date = new Date(y, m - 1, d)
  const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
  const months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
  return `${days[date.getDay()]}, ${months[m - 1]} ${d}`
}

function errorText(error) {
  const raw = (error && (error.message || String(error))) || 'The task service is unavailable.'
  const brace = raw.indexOf('{')
  if (brace !== -1) {
    try {
      const detail = JSON.parse(raw.slice(brace)).detail
      if (detail && detail.message) return detail.message
      if (typeof detail === 'string') return detail
    } catch {
      // not JSON
    }
  }
  return raw
}

// ── data ───────────────────────────────────────────────────────────────────────────────

function useLive(key, path) {
  const profile = useValue(host.state.profile)
  const gateway = useValue(host.state.gateway)
  return useQuery({
    enabled: gateway === 'open',
    queryFn: () => rest(path),
    queryKey: [ID, profile, ...key],
    refetchInterval: 15_000
  })
}

const useToday = () => useLive(['today', localISO()], `/today?day=${localISO()}`)
const useLadders = () => useLive(['ladders'], '/ladders')

function useActions() {
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: ({ path, method = 'PATCH', body }) => rest(path, { method, body }),
    onError: error => host.notifyError(error, 'Tasks could not save that change.'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: [ID] })
  })
  return { busy: mutation.isPending, run: input => mutation.mutateAsync(input) }
}

// ── bits ───────────────────────────────────────────────────────────────────────────────

function LadderPill({ ladder, styles }) {
  if (!ladder) return null
  const s = (styles && styles[ladder]) || { short: ladder, color: '#9aa4b2' }
  return jsx(Badge, { color: s.color, variant: 'outline', children: s.short })
}

function CardHeader({ title, hint, onAdd }) {
  return jsxs('div', {
    className: 'flex items-center gap-2',
    children: [
      jsx('span', { className: 'text-base font-semibold', children: title }),
      jsx('span', { className: `text-xs ${muted}`, children: hint }),
      jsx('div', { className: 'flex-1' }),
      onAdd ? jsx(Button, { size: 'sm', variant: 'ghost', onClick: onAdd, children: '+ Add' }) : null
    ]
  })
}

function RowMenu({ items }) {
  return jsxs(DropdownMenu, {
    children: [
      jsx(DropdownMenuTrigger, {
        asChild: true,
        children: jsx(Button, { size: 'icon-xs', variant: 'ghost', 'aria-label': 'More', children: jsx(Codicon, { name: 'ellipsis' }) })
      }),
      jsx(DropdownMenuContent, {
        align: 'end',
        children: items.filter(Boolean).map((it, i) =>
          it === '-'
            ? jsx(DropdownMenuSeparator, {}, `s${i}`)
            : jsx(DropdownMenuItem, { onSelect: it.run, disabled: it.disabled, children: it.label }, it.label)
        )
      })
    ]
  })
}

function Field({ label, children }) {
  return jsxs('label', { className: 'flex flex-col gap-1.5', children: [jsx('span', { className: fieldLabel, children: label }), children] })
}

function LadderSelect({ value, onChange, ladders }) {
  return jsxs('select', {
    value,
    onChange: e => onChange(valueOf(e)),
    children: [
      jsx('option', { value: '', children: 'No ladder' }, ''),
      ...Object.keys(ladders || {}).map(name => jsx('option', { value: name, children: name }, name))
    ]
  })
}

// ── daily queue ────────────────────────────────────────────────────────────────────────

function DailyRow({ item, styles, actions, onEdit }) {
  const pct = Math.min(100, Math.round((item.count / item.target) * 100))
  const glyph = item.done ? '✓' : item.count > 0 ? '◐' : '○'
  const add = n => actions.run({ path: `/daily/${item.id}/log`, method: 'POST', body: { add: n } })
  const streak = item.streak ? `${item.streak}-day streak · ${item.total} total` : `${item.total} total`
  return jsxs('div', {
    className: 'flex items-center gap-3 py-1.5',
    children: [
      jsx(Tip, {
        label: item.done ? 'Done for today' : 'Add one',
        children: jsx('button', { className: 'w-[22px] text-base', onClick: () => add(1), type: 'button', children: glyph })
      }),
      jsx('span', { className: 'w-[200px] text-sm truncate', children: item.title }),
      jsx('div', {
        className: 'flex-1 h-[4px]',
        children: jsx('div', { className: item.done ? `bg-[${GREEN}]` : 'bg-white', style: { width: `${pct}%` } })
      }),
      jsx('span', { className: 'w-[56px] text-sm text-right', children: `${item.count}/${item.target}` }),
      jsx('span', { className: `w-[180px] text-xs ${muted}`, children: streak }),
      jsx(RowMenu, {
        items: [
          { label: 'Add one', run: () => add(1) },
          { label: 'Take one off', run: () => add(-1), disabled: item.count === 0 },
          { label: 'Mark done for today', run: () => actions.run({ path: `/daily/${item.id}/log`, method: 'POST', body: { count: item.target } }) },
          '-',
          { label: 'Edit', run: () => onEdit(item) },
          { label: 'Stop tracking', run: () => actions.run({ path: `/daily/${item.id}`, method: 'DELETE' }) }
        ]
      })
    ]
  })
}

function DailyEditor({ item, preset, ladders, actions, onClose }) {
  const [title, setTitle] = useState(item ? item.title : '')
  const [ladder, setLadder] = useState(item ? item.ladder : preset || '')
  const [target, setTarget] = useState(item ? String(item.target) : '1')
  const save = async e => {
    if (e && e.preventDefault) e.preventDefault()
    const n = parseInt(target, 10)
    if (!title.trim() || !(n >= 1)) return
    try {
      await actions.run(
        item
          ? { path: `/daily/${item.id}`, body: { title: title.trim(), ladder, target: n } }
          : { path: '/daily', method: 'POST', body: { title: title.trim(), ladder, target: n } }
      )
      onClose()
    } catch {
      // reported by the mutation
    }
  }
  return jsx(Dialog, {
    open: true,
    onOpenChange: open => !open && onClose(),
    children: jsxs(DialogContent, {
      className: 'max-w-md',
      children: [
        jsx(DialogHeader, { children: jsx(DialogTitle, { children: item ? 'Edit daily action' : 'New daily action' }) }),
        jsxs('form', {
          className: 'flex flex-col gap-4',
          onSubmit: save,
          children: [
            jsx(Field, { label: 'Action', children: jsx(Input, { autoFocus: true, value: title, placeholder: 'LinkedIn DMs', onChange: e => setTitle(valueOf(e)) }) }),
            jsx(Field, { label: 'Per day', children: jsx(Input, { value: target, onChange: e => setTarget(valueOf(e)) }) }),
            jsx(Field, { label: 'Ladder', children: jsx(LadderSelect, { value: ladder, onChange: setLadder, ladders }) }),
            jsxs(DialogFooter, {
              children: [
                jsx(Button, { type: 'button', variant: 'ghost', onClick: onClose, children: 'Cancel' }),
                jsx(Button, { type: 'submit', onClick: save, disabled: actions.busy || !title.trim(), children: item ? 'Save' : 'Add' })
              ]
            })
          ]
        })
      ]
    })
  })
}

// ── execution queue ────────────────────────────────────────────────────────────────────

function ExecRow({ item, index, count, styles, actions, onEdit }) {
  const done = item.status === 'done'
  const age = done ? 'done today' : item.age_days === 0 ? 'new' : `day ${item.age_days}${item.stuck ? ' · stuck' : ''}`
  const move = delta => actions.run({ path: `/exec/${item.id}`, body: { position: index + delta } })
  return jsxs('div', {
    className: `flex items-center gap-3 py-1.5${done ? ' opacity-50' : ''}`,
    children: [
      jsx('span', { className: `w-[14px] text-xs ${muted}`, children: done ? '' : String(index + 1) }),
      jsx(Tip, {
        label: done ? 'Reopen' : 'Done',
        children: jsx('button', {
          className: 'w-[22px] text-base',
          type: 'button',
          onClick: () => actions.run({ path: `/exec/${item.id}`, body: { status: done ? 'open' : 'done' } }),
          children: done ? '✓' : '○'
        })
      }),
      jsx('button', {
        className: 'flex-1 text-sm text-left truncate',
        type: 'button',
        onClick: () => onEdit(item),
        children: item.title
      }),
      jsx('span', { className: `w-[420px] text-xs text-right truncate ${secondary}`, children: item.step || '' }),
      jsx('span', {
        className: `w-[96px] text-xs text-right ${item.stuck ? `text-[${AMBER}]` : muted}`,
        children: age
      }),
      jsx(RowMenu, {
        items: [
          { label: 'Open', run: () => onEdit(item) },
          done ? null : { label: 'Move up', run: () => move(-1), disabled: index === 0 },
          done ? null : { label: 'Move down', run: () => move(1), disabled: index >= count - 1 },
          '-',
          { label: 'Delete', run: () => actions.run({ path: `/exec/${item.id}`, method: 'DELETE' }) }
        ]
      })
    ]
  })
}

function ExecEditor({ item, preset, ladders, actions, onClose }) {
  const [title, setTitle] = useState(item ? item.title : '')
  const [ladder, setLadder] = useState(item ? item.ladder : preset || '')
  const [step, setStep] = useState(item ? item.step : '')
  const [notes, setNotes] = useState(item ? item.notes : '')
  const save = async e => {
    if (e && e.preventDefault) e.preventDefault()
    if (!title.trim()) return
    const body = { title: title.trim(), ladder, step, notes }
    try {
      await actions.run(item ? { path: `/exec/${item.id}`, body } : { path: '/exec', method: 'POST', body })
      onClose()
    } catch {
      // reported by the mutation
    }
  }
  return jsx(Dialog, {
    open: true,
    onOpenChange: open => !open && onClose(),
    children: jsxs(DialogContent, {
      className: 'max-w-lg',
      children: [
        jsx(DialogHeader, { children: jsx(DialogTitle, { children: item ? 'Execution item' : 'New execution item' }) }),
        jsxs('form', {
          className: 'flex flex-col gap-4',
          onSubmit: save,
          children: [
            jsx(Field, { label: 'Work', children: jsx(Input, { autoFocus: !item, value: title, onChange: e => setTitle(valueOf(e)) }) }),
            jsx(Field, { label: 'Ladder', children: jsx(LadderSelect, { value: ladder, onChange: setLadder, ladders }) }),
            jsx(Field, {
              label: 'Moves this step',
              children: jsx(Input, { value: step, placeholder: 'L1 Direct Accounts: first business buyer', onChange: e => setStep(valueOf(e)) })
            }),
            jsx(Field, { label: 'Notes', children: jsx(Textarea, { rows: 6, value: notes, onChange: e => setNotes(valueOf(e)) }) }),
            jsxs(DialogFooter, {
              children: [
                jsx(Button, { type: 'button', variant: 'ghost', onClick: onClose, children: 'Cancel' }),
                jsx(Button, { type: 'submit', onClick: save, disabled: actions.busy || !title.trim(), children: item ? 'Save' : 'Add' })
              ]
            })
          ]
        })
      ]
    })
  })
}

// ── pages ──────────────────────────────────────────────────────────────────────────────

function QueueLabel({ title, hint, onAdd }) {
  return jsxs('div', {
    className: 'flex items-center gap-2',
    children: [
      jsx('span', { className: fieldLabel, children: title }),
      jsx('span', { className: `text-xs ${muted}`, children: hint }),
      jsx('div', { className: 'flex-1' }),
      jsx(Button, { size: 'sm', variant: 'ghost', onClick: onAdd, children: '+ Add' })
    ]
  })
}

function DomainCard({ name, style, daily, execution, actions, onDaily, onExec }) {
  const open = execution.filter(x => x.status === 'open')
  const ids = open.map(x => x.id)
  const done = daily.filter(x => x.done).length
  const summary = [daily.length ? `${done} of ${daily.length} daily done` : null, open.length ? `${open.length} in execution` : null]
    .filter(Boolean)
    .join(' · ')
  return jsxs('div', {
    className: card,
    children: [
      jsxs('div', {
        className: 'flex items-center gap-2',
        children: [
          jsx('div', { className: `size-2.5 rounded-full bg-[${style.color}]` }),
          jsx('span', { className: 'text-base font-semibold', children: name }),
          jsx('span', { className: `text-xs ${muted}`, children: summary || 'nothing here yet' })
        ]
      }),
      jsxs('div', {
        className: 'flex flex-col',
        children: [
          jsx(QueueLabel, { title: 'Daily', hint: 'resets every morning', onAdd: () => onDaily({ fresh: true, ladder: name }) }),
          daily.length
            ? daily.map(item => jsx(DailyRow, { item, actions, onEdit: onDaily }, item.id))
            : jsx('span', { className: `text-sm py-1.5 ${muted}`, children: 'No daily actions for this domain.' })
        ]
      }),
      jsxs('div', {
        className: 'flex flex-col',
        children: [
          jsx(QueueLabel, { title: 'Execution', hint: 'carries over until done', onAdd: () => onExec({ fresh: true, ladder: name }) }),
          execution.length
            ? execution.map(item =>
                jsx(ExecRow, { item, index: ids.indexOf(item.id), count: ids.length, actions, onEdit: onExec }, item.id)
              )
            : jsx('span', { className: `text-sm py-1.5 ${muted}`, children: 'Nothing in execution for this domain.' })
        ]
      })
    ]
  })
}

function TodayView({ data, actions }) {
  const [dailyEdit, setDailyEdit] = useState(null) // null | { fresh, ladder } | item
  const [execEdit, setExecEdit] = useState(null)
  const styles = data.ladders
  const names = Object.keys(styles)
  const loose = x => !names.includes(x.ladder)
  const domains = names.map(name => ({ name, style: styles[name] }))
  if (data.daily.some(loose) || data.execution.some(loose)) domains.push({ name: '', style: { color: '#9aa4b2' } })
  return jsxs('div', {
    className: 'flex flex-col gap-4',
    children: [
      ...domains.map(d =>
        jsx(
          DomainCard,
          {
            name: d.name || 'No domain',
            style: d.style,
            daily: data.daily.filter(x => (d.name ? x.ladder === d.name : loose(x))),
            execution: data.execution.filter(x => (d.name ? x.ladder === d.name : loose(x))),
            actions,
            onDaily: setDailyEdit,
            onExec: setExecEdit
          },
          d.name || 'none'
        )
      ),
      dailyEdit
        ? jsx(DailyEditor, {
            item: dailyEdit.fresh ? null : dailyEdit,
            preset: dailyEdit.fresh ? dailyEdit.ladder : '',
            ladders: styles,
            actions,
            onClose: () => setDailyEdit(null)
          })
        : null,
      execEdit
        ? jsx(ExecEditor, {
            item: execEdit.fresh ? null : execEdit,
            preset: execEdit.fresh ? execEdit.ladder : '',
            ladders: styles,
            actions,
            onClose: () => setExecEdit(null)
          })
        : null
    ]
  })
}

function LevelColumn({ level, index, total, current, color }) {
  const reached = level.level <= current
  const next = level.level === current + 1
  const dot = reached ? `bg-[${color}]` : next ? `border-[${color}]` : 'bg-[#ffffff33]'
  const line = 'bg-[#ffffff22]'
  return jsxs('div', {
      className: 'flex flex-col items-center gap-1.5',
      children: [
        jsxs('div', {
          className: 'flex items-center w-full',
          children: [
            jsx('div', { className: `flex-1 h-px ${index === 0 ? 'bg-transparent' : line}` }),
            jsx('div', { className: `size-3 rounded-full ${dot}` }),
            jsx('div', { className: `flex-1 h-px ${index === total - 1 ? 'bg-transparent' : line}` })
          ]
        }),
        jsx('span', {
          className: `text-xs font-semibold text-center ${next ? `text-[${color}]` : ''}`,
          children: `L${level.level}  ${level.name}`
        }),
        jsx('span', { className: `text-[11px] text-center px-1 ${muted}`, children: level.gist })
      ]
    })
}

function LadderCard({ ladder }) {
  const counts = [ladder.open_exec ? `${ladder.open_exec} in execution` : null, ladder.daily ? `${ladder.daily} daily` : null]
    .filter(Boolean)
    .join(' · ')
  return jsxs('div', {
    className: card,
    children: [
      jsxs('div', {
        className: 'flex flex-col gap-1',
        children: [
          jsx('div', { className: 'text-base font-semibold', children: ladder.name }),
          jsx('div', { className: `text-sm ${secondary} line-clamp-2`, children: ladder.stand || 'Where you stand is not set yet.' })
        ]
      }),
      jsx('div', {
        className: `grid grid-cols-${ladder.levels.length} py-2`,
        children: ladder.levels.map((lv, i) =>
          jsx(LevelColumn, { level: lv, index: i, total: ladder.levels.length, current: ladder.current_level, color: ladder.color }, lv.level)
        )
      }),
      jsxs('div', {
        className: 'flex items-center gap-2',
        children: [
          jsx('span', { className: 'text-sm font-semibold', children: 'Next:' }),
          jsx('span', { className: `text-sm text-[${ladder.color}] truncate`, children: ladder.next_short || '—' }),
          jsx('div', { className: 'flex-1' }),
          jsx('span', { className: `text-xs ${muted}`, children: counts })
        ]
      })
    ]
  })
}

function LaddersView() {
  const { data, error, isLoading } = useLadders()
  if (error) return jsx(EmptyState, { title: 'Ladders unavailable', description: errorText(error) })
  if (isLoading || !data) return null
  if (!data.ladders.length)
    return jsx(EmptyState, { title: 'No ladders found', description: 'Vakra keeps them in life/ladders.md; none could be read.' })
  return jsx('div', { className: 'flex flex-col gap-4', children: data.ladders.map(l => jsx(LadderCard, { ladder: l }, l.name)) })
}

function TasksPage() {
  const [tab, setTab] = useState(DEFAULT_TAB)
  const { data, error } = useToday()
  const actions = useActions()
  const summary = data ? `${data.daily_done} of ${data.daily.length} daily done · ${data.open_exec} in execution` : ''
  return jsxs('div', {
    className: 'flex flex-col gap-4 h-full overflow-y-auto px-6 py-5',
    children: [
      jsxs('div', {
        className: 'flex items-start gap-3',
        children: [
          jsxs('div', {
            className: 'flex flex-col gap-1 flex-1',
            children: [
              jsx('div', { className: 'text-2xl font-semibold', children: longDate(data ? data.date : localISO()) }),
              jsx('div', { className: `text-sm ${secondary}`, children: summary })
            ]
          }),
          jsx(SegmentedControl, {
            value: tab,
            onChange: v => setTab(valueOf(v) === 'ladders' ? 'ladders' : 'today'),
            options: [
              { id: 'today', label: 'Today' },
              { id: 'ladders', label: 'Ladders' }
            ]
          })
        ]
      }),
      error
        ? jsx(EmptyState, {
            title: 'Task service unavailable',
            description: `${errorText(error)} The gateway needs one restart after the plugin is updated.`
          })
        : tab === 'ladders'
          ? jsx(LaddersView, {})
          : data
            ? jsx(TodayView, { data, actions })
            : null
    ]
  })
}

function TaskStatus() {
  const { data } = useToday()
  if (!data) return null
  return jsx(Tip, {
    label: `${data.daily_done} of ${data.daily.length} daily done · ${data.open_exec} in execution`,
    children: jsxs('button', {
      className: 'inline-flex h-full items-center gap-1 px-1.5 text-[0.6875rem] text-(--ui-text-tertiary)',
      onClick: () => host.navigate(ROUTE),
      type: 'button',
      children: [jsx(Codicon, { name: 'checklist', size: '0.7rem' }), jsx('span', { children: `${data.daily_done}/${data.daily.length}` })]
    })
  })
}

export default {
  id: ID,
  name: 'Tasks',
  defaultEnabled: true,
  register(ctx) {
    pluginContext = ctx
    ctx.registerMany([
      { id: 'page', area: ROUTES_AREA, data: { path: ROUTE }, render: () => jsx(TasksPage, {}) },
      { id: 'nav', area: SIDEBAR_NAV_AREA, order: 45, data: { path: ROUTE, label: 'Tasks', codicon: 'checklist' } },
      { id: 'status', area: STATUSBAR_AREAS.right, order: 75, render: () => jsx(TaskStatus, {}) },
      {
        id: 'open',
        area: PALETTE_AREA,
        data: {
          id: 'task-manager.open',
          label: 'Tasks: Open',
          keywords: ['tasks', 'todo', 'today', 'daily', 'execution', 'ladders'],
          run: () => host.navigate(ROUTE)
        }
      }
    ])
  }
}
