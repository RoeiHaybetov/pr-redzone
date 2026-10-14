import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Alert, Badge, Button, EmptyState, ExpandableRow, Meta, MetaItem } from '@pr/ui'
import { post } from '../../lib'
import { useAdmin } from '../core'
import { Groups } from '../fields'

function stateOf(z) {
  if (!z) return 'unknown'
  if (!z.enabled) return 'disabled'
  return z.open ? 'open' : 'closed'
}

export default function Zones() {
  const { cfg, isChanged, resetPath, setZones, setValue, draftZones, notify, ask, reload, setActive } = useAdmin()

  const [live, setLive] = useState(null)

  const loadLive = useCallback(async () => {
    const r = await post('rzAdminDashboard', {})
    setLive(r && r.ok ? r.data || null : null)
  }, [])

  useEffect(() => { loadLive() }, [loadLive])

  const baseZones = useMemo(
    () => draftZones || cfg.zoneStructure || {},
    [draftZones, cfg.zoneStructure],
  )

  const baseRef = useRef(baseZones)
  baseRef.current = baseZones

  const liveRef = useRef(cfg.zones)
  liveRef.current = cfg.zones || []

  const pendingRef = useRef(null)

  useEffect(() => {
    const onMessage = (e) => {
      const msg = e.data || {}
      if (msg.action !== 'rzAdminPolygonDone') return

      const zoneId = pendingRef.current
      pendingRef.current = null
      if (!zoneId) return

      const d = msg.data || {}
      if (!d.confirmed || !Array.isArray(d.points) || d.points.length < 3) return

      const base = baseRef.current
      setZones({
        ...base,
        [zoneId]: { ...(base[zoneId] || {}), points: d.points, minZ: d.minZ, maxZ: d.maxZ },
      })
      if ((liveRef.current || []).includes(zoneId)) {
        setValue(`Zones.${zoneId}.minZ`, d.minZ)
        setValue(`Zones.${zoneId}.maxZ`, d.maxZ)
      }
      notify(`Shape captured — ${d.points.length} points. Publish to apply.`)
    }

    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [setZones, setValue, notify])

  const liveZones = live && live.zones

  const info = useMemo(() => {
    const map = {}
    for (const z of liveZones || []) map[z.id] = z
    return map
  }, [liveZones])

  const ids = useMemo(() => {
    const out = [...(cfg.zones || [])]
    for (const id of Object.keys(baseZones)) if (!out.includes(id)) out.push(id)
    return out
  }, [cfg.zones, baseZones])

  const run = useCallback((action, zoneId, destructive, label) => {
    const go = async () => {
      const res = await post('rzAdminControl', { action, payload: { zoneId } })
      notify(res.message || res.error || (res.ok ? 'Done.' : 'Failed.'), !res.ok)
      if (!res.ok) return
      await reload()
      await loadLive()
    }

    if (!destructive) { go(); return }

    ask({
      title: 'Confirm',
      body: `${label}. This affects the live server immediately.`,
      confirmLabel: 'Do it',
      danger: true,
      onConfirm: go,
    })
  }, [notify, ask, reload, loadLive])

  const redraw = useCallback(async (zoneId) => {
    pendingRef.current = zoneId
    const res = await post('rzAdminPolygon', { points: (baseRef.current[zoneId] || {}).points || [] })
    if (res && res.ok === false) {
      pendingRef.current = null
      if (res.error) notify(res.error, true)
    }
  }, [notify])

  const remove = useCallback((zoneId, label) => ask({
    title: `Delete ${label}?`,
    body: 'The zone is removed from the draft, along with any unsaved edits to it. Press Publish '
      + 'and it is gone straight away: anyone inside is released, and its crate, loot bags and '
      + 'session end.',
    confirmLabel: 'Delete',
    danger: true,
    onConfirm: () => {
      const next = { ...baseRef.current }
      delete next[zoneId]
      setZones(next)
      cfg.fields.forEach((f) => { if (f.zoneId === zoneId) resetPath(f.path) })
      notify(`"${label}" is queued for removal. Publish to apply.`)
    },
  }), [ask, cfg.fields, resetPath, setZones, notify])

  const restore = useCallback((zoneId, label) => {
    const original = (cfg.zoneStructure || {})[zoneId]
    if (!original) return
    setZones({ ...baseRef.current, [zoneId]: original })
    notify(`"${label}" will be kept.`)
  }, [cfg.zoneStructure, setZones, notify])

  return (
    <>
      <div className="rz-actions-row">
        <Button variant="primary" icon="fa-plus" onClick={() => setActive('create')}>
          Create a zone
        </Button>
      </div>

      {ids.length === 0 ? (
        <EmptyState
          icon="fa-map-location-dot"
          title="No zones yet."
          hint="Create one with the wizard: draw the shape in the world, place the crate, the seller and at least one reboot station, then publish."
        />
      ) : null}

      {ids.map((id, i) => {
        const z = info[id]
        const zone = baseZones[id]
        const removed = !zone
        const isNew = !(cfg.zones || []).includes(id)
        const label = (z && z.label) || (zone && zone.label) || id
        const fields = cfg.fields.filter((f) => f.zoneId === id)
        const changed = fields.reduce((n, f) => (isChanged(f.path) ? n + 1 : n), 0)

        return (
          <ExpandableRow
            key={id}
            title={label}
            icon="fa-location-dot"
            muted={removed}
            defaultOpen={ids.length === 1 && i === 0}
            meta={(
              <Meta>
                <MetaItem icon="fa-hashtag">{id}</MetaItem>
                <Badge>{removed ? 'removing' : isNew ? 'new' : stateOf(z)}</Badge>
                {changed ? <Badge count={changed}>changed</Badge> : null}
              </Meta>
            )}
            actions={removed ? null : (
              <>
                <Button variant="ghost" onClick={() => run('zone_force_open', id, false, 'Force open')}>
                  Force open
                </Button>
                <Button variant="danger" onClick={() => run('zone_force_close', id, true, 'Force close')}>
                  Force close
                </Button>
                <Button variant="ghost" onClick={() => run('zone_schedule', id, false, 'Back to schedule')}>
                  Back to schedule
                </Button>
              </>
            )}
          >
            {removed ? (
              <>
                <Alert>
                  This zone is deleted in the draft. Publishing removes it from the server for good.
                </Alert>
                <div className="rz-actions-row">
                  <Button icon="fa-rotate-left" onClick={() => restore(id, label)}>Keep the zone</Button>
                </div>
              </>
            ) : (
              <>
                {isNew ? (
                  <Alert>
                    Drawn but not published yet. Its settings appear here once it is live.
                  </Alert>
                ) : (
                  <Groups fields={fields} />
                )}

                <div className="rz-actions-row">
                  <Button icon="fa-draw-polygon" onClick={() => redraw(id)}>Redraw shape</Button>
                  {isNew ? null : (
                    <>
                      <Button
                        variant="danger"
                        icon="fa-arrows-rotate"
                        onClick={() => run('crate_reset', id, true, `Reset crate timer — ${label}`)}
                      >
                        Reset crate timer
                      </Button>
                      <Button
                        variant="danger"
                        icon="fa-box-open"
                        onClick={() => run('crate_despawn', id, true, `Despawn crate — ${label}`)}
                      >
                        Despawn crate
                      </Button>
                    </>
                  )}
                  <Button variant="danger" icon="fa-trash" onClick={() => remove(id, label)}>
                    Delete zone
                  </Button>
                </div>
              </>
            )}
          </ExpandableRow>
        )
      })}
    </>
  )
}
