import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import {
  Badge, Button, CloseButton, Divider, NavItem, NavList, Panel, PanelHeader,
  SearchField, Shell, useDeferredClose, useNuiEvent,
} from '@pr/ui'
import { post, useConfirm } from '../lib'
import { AdminContext, DialogHost, same } from './core'
import { Groups } from './fields'
import Overview from './views/Overview'
import Zones from './views/Zones'
import Settings from './views/Settings'
import Server from './views/Server'
import Create from './views/Create'

const EMPTY = {
  revision: 0,
  schemaVersion: 1,
  capabilities: {},
  sections: [],
  fields: [],
  zones: [],
  zoneStructure: null,
  webhookConfigured: false,
  suggestions: {},
}

const ICONS = {
  gauge: 'fa-gauge-high',
  map: 'fa-map-location-dot',
  crosshairs: 'fa-crosshairs',
  cash: 'fa-sack-dollar',
  users: 'fa-users',
  sliders: 'fa-sliders',
  shield: 'fa-shield-halved',
  server: 'fa-server',
}

const VIEWS = {
  overview: Overview,
  zones: Zones,
  server: Server,
  create: Create,
}

const ZONE_SECTION = 'zones'

const MODE_BODY = {
  restart: 'Some changes need a resource restart.',
  session: 'Zones are being added, reshaped or removed. That can wait for the next RedZone session, or be applied now.',
  live: 'All changes can be applied immediately.',
}

const STALE = 'The RedZone configuration was changed by another administrator. Reload the latest revision before publishing.'

async function sendPublish(env, payload, applyMode, ackWarnings) {
  const opts = {
    baseRevision: env.revision,
    applyMode,
    acknowledgeWarnings: ackWarnings,
    reason: null,
  }

  const res = await post('rzAdminPublish', { draft: payload, opts })

  if (!res.ok) {
    if (res.stale) {
      env.setRevision(res.revision)
      return { error: STALE }
    }
    return { error: (res.errors && res.errors[0]) || 'Publish failed.' }
  }

  env.clearDraft()
  env.setRevision(res.revision)
  env.notify(res.deferred
    ? `Saved as revision ${res.revision}. It will apply when the current session ends.`
    : `Published revision ${res.revision}.`)

  await env.reload()
  return null
}

async function reviewPublish(env, payload, count) {
  const v = await post('rzAdminValidate', { draft: payload })

  if (!v.ok) {
    env.setFieldErrors(v.fieldErrors || {})
    env.ask({
      title: 'Cannot publish',
      body: 'Fix the problems below and try again.',
      list: (v.errors || []).map((e) => ({ kind: 'error', text: e })),
      buttons: [],
    })
    return
  }

  const entries = (v.warnings || []).map((w) => ({ kind: 'warn', text: w }))
  const mode = payload.zones && v.applyMode === 'live' ? 'session' : v.applyMode
  const buttons = []

  if (mode === 'session') {
    buttons.push({
      label: 'Apply next session',
      fn: () => sendPublish(env, payload, 'session', entries.length > 0),
    })
  }

  buttons.push({
    label: 'Apply now',
    danger: mode !== 'live',
    fn: () => sendPublish(env, payload, 'live', entries.length > 0),
  })

  env.ask({
    title: `Publish ${count} change(s)?`,
    body: MODE_BODY[mode] || MODE_BODY.live,
    list: entries,
    diff: v.diff,
    wide: true,
    buttons,
  })
}

export default function AdminPanel() {
  const [open, setOpen] = useState(false)
  const [hidden, setHidden] = useState(false)
  const [cfg, setCfg] = useState(EMPTY)
  const [published, setPublished] = useState({})
  const [draft, setDraft] = useState({})
  const [draftZones, setDraftZones] = useState(null)
  const [fieldErrors, setFieldErrors] = useState({})
  const [active, setActive] = useState('overview')
  const [search, setSearch] = useState('')
  const [toast, setToast] = useState(null)

  const confirm = useConfirm()
  const { ask, close: closeDialog } = confirm
  const { mounted, leaving } = useDeferredClose(open)
  const toastTimer = useRef(0)
  const dialogRef = useRef(null)

  useEffect(() => { dialogRef.current = confirm.dialog }, [confirm.dialog])
  useEffect(() => () => clearTimeout(toastTimer.current), [])

  const notify = useCallback((message, bad) => {
    clearTimeout(toastTimer.current)
    setToast({ message, bad: !!bad })
    toastTimer.current = setTimeout(() => setToast(null), 3800)
  }, [])

  const clearDraft = useCallback(() => {
    setDraft({})
    setDraftZones(null)
    setFieldErrors({})
  }, [])

  const loadConfig = useCallback((c) => {
    const fields = c.fields || []
    const next = {}
    fields.forEach((f) => { next[f.path] = f.value })
    setPublished(next)
    setCfg((prev) => ({
      ...prev,
      sections: c.sections || [],
      fields,
      zones: c.zones || [],
      zoneStructure: c.zoneStructure || null,
      webhookConfigured: !!c.webhookConfigured,
      suggestions: c.suggestions || {},
    }))
  }, [])

  useNuiEvent('rzAdminOpen', (data) => {
    const d = data || {}
    const c = d.config || {}
    const first = (c.sections && c.sections[0] && c.sections[0].id) || 'overview'

    setCfg({ ...EMPTY, revision: d.revision || 0, schemaVersion: d.schemaVersion || 1, capabilities: d.capabilities || {} })
    loadConfig(c)
    clearDraft()
    setActive(d.view === 'create' ? 'create' : first)
    setSearch('')
    setHidden(false)
    setOpen(true)
  })

  useNuiEvent('rzAdminClose', () => {
    setOpen(false)
    closeDialog()
  })

  useNuiEvent('rzAdminHidden', (data) => setHidden(!!(data && data.hidden)))

  const valueOf = useCallback(
    (path) => (path in draft ? draft[path] : published[path]),
    [draft, published],
  )

  const isChanged = useCallback(
    (path) => path in draft && !same(draft[path], published[path]),
    [draft, published],
  )

  const setValue = useCallback((path, value) => {
    setDraft((prev) => {
      const next = { ...prev }
      if (same(value, published[path])) delete next[path]
      else next[path] = value
      return next
    })
    setFieldErrors((prev) => {
      if (!(path in prev)) return prev
      const next = { ...prev }
      delete next[path]
      return next
    })
  }, [published])

  const resetPath = useCallback((path) => {
    setDraft((prev) => {
      const next = { ...prev }
      delete next[path]
      return next
    })
  }, [])

  const setZones = useCallback((zones) => {
    setDraftZones(zones && same(zones, cfg.zoneStructure) ? null : zones)
  }, [cfg.zoneStructure])

  useNuiEvent('rzAdminPlacementDone', (data) => {
    const d = data || {}
    if (d.confirmed && d.path) {
      setValue(d.path, d.coords)
      notify('Position captured.')
    }
  })

  const changedPaths = useMemo(
    () => Object.keys(draft).filter((p) => !same(draft[p], published[p])),
    [draft, published],
  )

  const changeCount = changedPaths.length + (draftZones ? 1 : 0)
  const dirty = changeCount > 0

  const matches = useMemo(() => {
    const term = search.trim().toLowerCase()
    if (!term) return null
    return cfg.fields.filter((f) =>
      (f.label && f.label.toLowerCase().includes(term))
      || (f.path && f.path.toLowerCase().includes(term))
      || (f.desc && f.desc.toLowerCase().includes(term)))
  }, [cfg.fields, search])

  const close = useCallback(() => {
    setOpen(false)
    closeDialog()
    post('rzAdminClose', {})
  }, [closeDialog])

  useEffect(() => {
    if (!open) return undefined
    const onKey = (e) => {
      if (e.key !== 'Escape') return
      const tag = (e.target && e.target.tagName) || ''
      if (tag === 'INPUT' || tag === 'TEXTAREA') { e.target.blur(); return }
      if (dialogRef.current) { closeDialog(); return }
      close()
    }
    window.addEventListener('keyup', onKey)
    return () => window.removeEventListener('keyup', onKey)
  }, [open, close, closeDialog])

  const reload = useCallback(async () => {
    const r = await post('rzAdminRefresh', {})
    if (!r || !r.ok) return
    setCfg((prev) => ({ ...prev, revision: r.revision }))
    loadConfig(r)
  }, [loadConfig])

  const env = useMemo(() => ({
    revision: cfg.revision,
    setRevision: (n) => setCfg((prev) => ({ ...prev, revision: n })),
    setFieldErrors,
    clearDraft,
    notify,
    ask,
    reload,
  }), [cfg.revision, clearDraft, notify, ask, reload])

  const publish = useCallback(() => {
    if (!dirty) return undefined
    const payload = { fields: {} }
    changedPaths.forEach((p) => { payload.fields[p] = draft[p] })
    if (draftZones) payload.zones = draftZones
    return reviewPublish(env, payload, changeCount)
  }, [changeCount, changedPaths, dirty, draft, draftZones, env])

  const discard = useCallback(() => ask({
    title: 'Discard the draft?',
    body: 'Every unsaved change is lost. Published settings are unaffected.',
    confirmLabel: 'Discard',
    danger: true,
    onConfirm: clearDraft,
  }), [ask, clearDraft])

  const ctx = useMemo(() => ({
    cfg, valueOf, isChanged, setValue, resetPath, setZones, draftZones,
    fieldErrors, notify, ask, reload, search, active, setActive,
  }), [cfg, valueOf, isChanged, setValue, resetPath, setZones, draftZones, fieldErrors, notify, ask, reload, search, active])

  if (!mounted) return null

  const section = cfg.sections.find((s) => s.id === active)
  const heading = search ? `Search: ${search}`
    : section ? section.label
      : active === 'create' ? 'Create a zone' : ''
  const View = VIEWS[active]

  const body = matches
    ? <Groups fields={matches} expanded empty={`Nothing matches “${search}”.`} />
    : View ? <View section={active} /> : <Settings section={active} />

  return (
    <AdminContext.Provider value={ctx}>
      <div className="rz-admin-root" style={hidden ? { visibility: 'hidden' } : undefined}>
        <Shell closing={leaving}>
          <Panel width={1240} height={760}>
            <PanelHeader title="REDZONE" subtitle="Administration">
              <Button variant="ghost" icon="fa-rotate-left" disabled={!dirty} onClick={discard}>
                Discard draft
              </Button>
              <Button variant="primary" icon="fa-cloud-arrow-up" disabled={!dirty} onClick={publish}>
                Publish changes
              </Button>
              <CloseButton onClick={close} />
            </PanelHeader>

            <Divider />

            <div className="rz-admin-shell">
              <aside className="rz-admin-side">
                <SearchField
                  value={search}
                  placeholder="Search settings…"
                  submitLabel="Go"
                  onChange={(v) => setSearch(v.trim())}
                  onSubmit={(v) => setSearch(v.trim())}
                  onClear={search ? () => setSearch('') : undefined}
                />

                <div className="rz-admin-nav">
                  <NavList>
                    {cfg.sections.map((s, i) => {
                      const n = cfg.fields.filter((f) => f.section === s.id && isChanged(f.path)).length
                        + (draftZones && s.id === ZONE_SECTION ? 1 : 0)

                      return (
                        <NavItem
                          key={s.id}
                          index={i}
                          icon={ICONS[s.icon] || 'fa-gear'}
                          label={s.label}
                          active={!search && (s.id === active || (active === 'create' && s.id === ZONE_SECTION))}
                          badge={n > 0 ? <Badge count={n} /> : null}
                          onClick={() => { setActive(s.id); setSearch('') }}
                        />
                      )
                    })}
                  </NavList>
                </div>

                <div className="rz-admin-side-foot">
                  <div className="rz-admin-rev">
                    <span>Revision</span>
                    <span className="rz-num">{cfg.revision}</span>
                  </div>
                  {dirty ? (
                    <div className="rz-admin-rev">
                      <span>Unsaved</span>
                      <span className="rz-num">{changeCount} change(s)</span>
                    </div>
                  ) : null}
                </div>
              </aside>

              <main className="rz-admin-main">
                <div className="rz-admin-body rz-scrollable">
                  {heading ? (
                    <div className="rz-view-head">
                      <h2>{heading}</h2>
                      {search ? <span>Showing matches across every section</span> : null}
                    </div>
                  ) : null}
                  {body}
                </div>
              </main>
            </div>
          </Panel>
        </Shell>

        <DialogHost confirm={confirm} />

        {toast ? (
          <div className={`rz-admin-toast ${toast.bad ? 'is-bad' : ''}`.trim()}>{toast.message}</div>
        ) : null}
      </div>
    </AdminContext.Provider>
  )
}
