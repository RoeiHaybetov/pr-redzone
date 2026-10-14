import { useCallback, useEffect, useMemo, useState } from 'react'
import { Alert, Button, EmptyState, Input, Section } from '@pr/ui'
import { post } from '../../lib'
import { useAdmin } from '../core'

const STEPS = [
  { id: 'name', label: 'Name', icon: 'fa-tag' },
  { id: 'shape', label: 'Shape', icon: 'fa-draw-polygon',
    lede: 'Fly to the area and drop a point at each corner. The zone is whatever those points enclose — three points minimum, and the edges may not cross.' },
  { id: 'schedule', label: 'Schedule', icon: 'fa-clock' },
  { id: 'crate', label: 'Crate', icon: 'fa-box',
    lede: 'The crate spawns once one group has held the zone uncontested. It must sit inside the shape you drew.' },
  { id: 'seller', label: 'Seller', icon: 'fa-user-tie',
    lede: 'Where the buyer stands. Aim at the ground and rotate with the arrow keys to set which way they face.' },
  { id: 'stations', label: 'Reboot', title: 'Reboot stations', icon: 'fa-plug',
    lede: 'Where a teammate is brought back. Each station needs a prop and a spawn position clear of that prop footprint.' },
  { id: 'review', label: 'Review', icon: 'fa-clipboard-check' },
]

const HOURS = [
  { key: 'openHour', label: 'Opens at', desc: 'Hour of the day, 0–23.', min: 0, max: 23 },
  { key: 'closeHour', label: 'Closes at', min: 0, max: 23,
    desc: 'A closing hour earlier than the opening hour means the window crosses midnight.' },
  { key: 'utcOffset', label: 'UTC offset', min: -12, max: 14, step: '0.5', placeholder: 'server default',
    desc: 'Hours ahead of UTC those times are read in. Leave blank to follow the server offset. No daylight saving is applied.' },
]

const EMPTY_DRAFT = {
  name: '', points: null, minZ: null, maxZ: null,
  openHour: 20, closeHour: 6, utcOffset: '',
  crate: null, rewardItem: '', seller: null, stations: [],
}

const hour = (v) => (String(v).trim() === '' ? NaN : Number(v))

function slugify(name) {
  return String(name || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 32)
}

function fmt(c, dp = 1) {
  if (!c) return '—'
  const n = (v) => Number(v).toFixed(dp)
  return c.w === undefined || c.w === null
    ? `${n(c.x)}, ${n(c.y)}, ${n(c.z)}`
    : `${n(c.x)}, ${n(c.y)}, ${n(c.z)} @ ${n(c.w)}°`
}

function WizField({ id, label, desc, children }) {
  return (
    <div className="rz-field">
      <div className="rz-field-label">
        <label htmlFor={id}>{label}</label>
        <div className="rz-field-desc">{desc}</div>
      </div>
      <div className="rz-field-input">{children}</div>
    </div>
  )
}

function Fact({ label, value, plain = false }) {
  return <div><span>{label}</span><span className={plain ? undefined : 'rz-num'}>{value}</span></div>
}

function PlaceRow({ variant = 'primary', label, coords, onClick }) {
  return (
    <div className="rz-actions-row">
      <Button variant={variant} icon="fa-location-crosshairs" onClick={onClick}>{label}</Button>
      <span className="rz-num">{fmt(coords)}</span>
    </div>
  )
}

const BODIES = {
  name: ({ draft, set, zoneId }) => (
    <>
      <WizField id="rz-zone-name" label="Display name"
        desc="Shown on the map and in every message about this zone.">
        <Input id="rz-zone-name" value={draft.name} maxLength={64} placeholder="Sandy Shores Shootout"
          onChange={(e) => set({ name: e.target.value })} />
      </WizField>
      <WizField label="Zone id"
        desc="Generated from the name. Used as the database key and in every log line, so it is fixed once the zone exists.">
        <span className="rz-num">{zoneId || '—'}</span>
      </WizField>
    </>
  ),

  shape: ({ draft, editShape }) => (
    <>
      <div className="rz-actions-row">
        <Button variant="primary" icon="fa-draw-polygon" onClick={editShape}>
          {draft.points ? 'Redraw the shape' : 'Draw the shape'}
        </Button>
      </div>
      {draft.points ? (
        <div className="rz-wizard-facts">
          <Fact label="Points" value={draft.points.length} />
          <Fact label="Floor" value={`${Number(draft.minZ).toFixed(0)}m`} />
          <Fact label="Ceiling" value={`${Number(draft.maxZ).toFixed(0)}m`} />
        </div>
      ) : <EmptyState icon="fa-draw-polygon" title="No shape drawn yet." />}
    </>
  ),

  schedule: ({ draft, set }) => HOURS.map((h) => (
    <WizField key={h.key} id={`rz-${h.key}`} label={h.label} desc={h.desc}>
      <Input id={`rz-${h.key}`} type="number" min={h.min} max={h.max} step={h.step}
        placeholder={h.placeholder} value={draft[h.key]}
        onChange={(e) => set({ [h.key]: e.target.value })} />
    </WizField>
  )),

  crate: ({ draft, set, place }) => (
    <>
      <PlaceRow label={draft.crate ? 'Move the crate' : 'Place the crate'} coords={draft.crate}
        onClick={() => place('crate', 'prop', 'ex_prop_crate_gems_bc')} />
      <WizField id="rz-reward" label="Reward item"
        desc="What the crate gives and the seller buys. It must exist in your inventory.">
        <Input id="rz-reward" value={draft.rewardItem} placeholder="hippy_meth_box"
          onChange={(e) => set({ rewardItem: e.target.value })} />
      </WizField>
    </>
  ),

  seller: ({ draft, place }) => (
    <PlaceRow label={draft.seller ? 'Move the seller' : 'Place the seller'} coords={draft.seller}
      onClick={() => place('seller', 'ped', 's_m_y_dealer_01')} />
  ),

  stations: ({ draft, place, addStation, removeStation }) => (
    <>
      {draft.stations.map((s, i) => (
        <div className="rz-wizard-station" key={i}>
          <div className="rz-wizard-station-head">
            <span>Station {i + 1}</span>
            <Button variant="ghost" icon="fa-trash" onClick={() => removeStation(i)}>Remove</Button>
          </div>
          <PlaceRow variant="default" label="Prop" coords={s.propCoords}
            onClick={() => place(`station:${i}`, 'prop', 'ex_prop_crate_elec_bc', 'propCoords')} />
          <PlaceRow variant="default" label="Spawn" coords={s.playerSpawn}
            onClick={() => place(`station:${i}`, 'coords', null, 'playerSpawn')} />
        </div>
      ))}
      <div className="rz-actions-row">
        <Button icon="fa-plus" onClick={addStation}>Add a station</Button>
      </div>
    </>
  ),

  review: ({ draft, zoneId, problems, ready }) => (
    <>
      <div className="rz-wizard-facts">
        <Fact label="Name" value={draft.name || '—'} plain />
        <Fact label="Id" value={zoneId || '—'} />
        <Fact label="Points" value={draft.points ? draft.points.length : 0} />
        <Fact label="Hours" value={`${draft.openHour}:00 → ${draft.closeHour}:00`} />
        <Fact label="Crate" value={fmt(draft.crate, 0)} />
        <Fact label="Reward" value={draft.rewardItem || '—'} plain />
        <Fact label="Seller" value={fmt(draft.seller, 0)} />
        <Fact label="Stations" value={draft.stations.length} />
      </div>
      {ready ? (
        <Alert>
          Creating adds the zone to the draft. Nothing goes live until you publish, and the server
          validates every position against the shape before it accepts it.
        </Alert>
      ) : (
        <div className="rz-warn-list">
          {Object.keys(problems).map((k) => (
            <div className="rz-warn-item is-error" key={k}>{problems[k]}</div>
          ))}
        </div>
      )}
    </>
  ),
}

export default function Create() {
  const { cfg, notify, ask, setZones, draftZones, setActive } = useAdmin()

  const baseZones = draftZones || cfg.zoneStructure || {}

  const [step, setStep] = useState(0)
  const [draft, setDraft] = useState(EMPTY_DRAFT)
  const [busy, setBusy] = useState(false)

  const set = useCallback((patch) => setDraft((d) => ({ ...d, ...patch })), [])

  useEffect(() => {
    const onMessage = (e) => {
      const msg = e.data || {}

      if (msg.action === 'rzAdminPolygonDone') {
        const d = msg.data || {}
        if (d.confirmed && Array.isArray(d.points) && d.points.length >= 3) {
          set({ points: d.points, minZ: d.minZ, maxZ: d.maxZ })
          notify(`Shape captured — ${d.points.length} points.`)
        }
      }

      if (msg.action === 'rzAdminCreatePlacementDone') {
        const d = msg.data || {}
        if (!d.confirmed) return
        if (d.slot === 'crate') set({ crate: d.coords })
        else if (d.slot === 'seller') set({ seller: d.coords })
        else if (d.slot && d.slot.startsWith('station:')) {
          const i = Number(d.slot.split(':')[1])
          setDraft((prev) => ({
            ...prev,
            stations: prev.stations.map((s, idx) => (idx === i ? { ...s, ...d.patch } : s)),
          }))
        }
        notify('Position captured.')
      }
    }

    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [set, notify])

  const zoneId = useMemo(() => slugify(draft.name), [draft.name])
  const takenIds = useMemo(() => new Set(Object.keys(baseZones)), [baseZones])

  const problems = useMemo(() => {
    const out = {}
    if (!draft.name.trim()) out.name = 'Give the zone a name.'
    else if (!zoneId) out.name = 'That name has no letters or numbers in it.'
    else if (takenIds.has(zoneId)) out.name = `A zone with the id "${zoneId}" already exists.`

    if (!draft.points || draft.points.length < 3) out.shape = 'Draw the zone shape.'

    const oh = hour(draft.openHour)
    const ch = hour(draft.closeHour)
    if (!Number.isInteger(oh) || oh < 0 || oh > 23 || !Number.isInteger(ch) || ch < 0 || ch > 23) {
      out.schedule = 'Opening and closing hours must be whole hours between 0 and 23.'
    } else if (oh === ch) {
      out.schedule = 'Opening and closing hour cannot be the same.'
    }

    if (String(draft.utcOffset).trim() !== '') {
      const offset = Number(draft.utcOffset)
      if (!isFinite(offset) || offset < -12 || offset > 14) {
        out.schedule = out.schedule || 'UTC offset must be between -12 and 14, or blank.'
      }
    }

    if (!draft.crate) out.crate = 'Place the crate.'
    if (!draft.rewardItem.trim()) out.crate = out.crate || 'Name the item the crate gives.'
    if (!draft.seller) out.seller = 'Place the seller.'
    if (!draft.stations.length) out.stations = 'Add at least one reboot station.'
    else if (draft.stations.some((s) => !s.propCoords || !s.playerSpawn)) {
      out.stations = 'Every station needs both a prop position and a spawn position.'
    }
    return out
  }, [draft, zoneId, takenIds])

  const stepDef = STEPS[step]
  const stepProblem = problems[stepDef.id]
  const ready = Object.keys(problems).length === 0

  const editShape = useCallback(async () => {
    const res = await post('rzAdminPolygon', { points: draft.points || [] })
    if (res && res.ok === false && res.error) notify(res.error, true)
  }, [draft.points, notify])

  const place = useCallback(async (slot, kind, model, patchKey) => {
    const res = await post('rzAdminCreatePlace', { slot, kind, model, patchKey })
    if (res && res.ok === false && res.error) notify(res.error, true)
  }, [notify])

  const addStation = useCallback(() => setDraft((d) => ({
    ...d,
    stations: [...d.stations, { propCoords: null, playerSpawn: null, useExistingProp: false }],
  })), [])

  const removeStation = useCallback((i) => setDraft((d) => ({
    ...d, stations: d.stations.filter((_, idx) => idx !== i),
  })), [])

  const reset = useCallback(() => {
    setDraft(EMPTY_DRAFT)
    setStep(0)
    setActive('zones')
  }, [setActive])

  const create = useCallback(async () => {
    if (!ready || busy) return
    setBusy(true)

    const zone = {
      enabled: true,
      label: draft.name.trim(),
      points: draft.points,
      minZ: draft.minZ,
      maxZ: draft.maxZ,
      package: draft.rewardItem.trim(),
      schedule: { openHour: Number(draft.openHour), closeHour: Number(draft.closeHour) },
      crate: { coords: draft.crate, rewardItem: draft.rewardItem.trim() },
      seller: { coords: draft.seller },
      rebootStations: draft.stations.map((s) => ({
        propCoords: s.propCoords,
        playerSpawn: s.playerSpawn,
        ...(s.prop ? { prop: s.prop } : {}),
        ...(s.useExistingProp ? { useExistingProp: true } : {}),
      })),
    }
    if (String(draft.utcOffset).trim() !== '') zone.schedule.utcOffset = Number(draft.utcOffset)

    setZones({ ...baseZones, [zoneId]: zone })
    setBusy(false)

    notify(`"${draft.name.trim()}" is ready. Publish to make it live.`)
    reset()
  }, [ready, busy, draft, zoneId, baseZones, setZones, notify, reset])

  const cancel = () => ask({
    title: 'Cancel the new zone?',
    body: 'Everything entered here is discarded.',
    confirmLabel: 'Discard',
    danger: true,
    onConfirm: reset,
  })

  return (
    <>
      <div className="rz-wizard-steps">
        {STEPS.map((s, i) => (
          <button key={s.id} type="button" onClick={() => setStep(i)}
            className={`rz-wizard-step${i === step ? ' is-active' : ''}${i < step ? ' is-done' : ''}`}>
            <i className={`fa-solid ${s.icon}`} aria-hidden="true" />
            <span>{s.label}</span>
          </button>
        ))}
      </div>

      <Section title={stepDef.title || stepDef.label} icon={stepDef.icon}>
        {stepDef.lede ? <div className="rz-wizard-lede">{stepDef.lede}</div> : null}
        {BODIES[stepDef.id]({
          draft, set, zoneId, problems, ready, editShape, place, addStation, removeStation,
        })}
      </Section>

      {stepProblem && stepDef.id !== 'review' ? (
        <div className="rz-warn-list"><div className="rz-warn-item is-error">{stepProblem}</div></div>
      ) : null}

      <div className="rz-wizard-nav">
        <Button variant="ghost" icon="fa-arrow-left" disabled={step === 0}
          onClick={() => setStep((s) => Math.max(0, s - 1))}>
          Back
        </Button>
        <Button variant="ghost" icon="fa-xmark" onClick={cancel}>Cancel</Button>
        {step < STEPS.length - 1 ? (
          <Button variant="primary" icon="fa-arrow-right"
            onClick={() => setStep((s) => Math.min(STEPS.length - 1, s + 1))}>
            Next
          </Button>
        ) : (
          <Button variant="primary" icon="fa-check" disabled={!ready || busy} onClick={create}>
            Create zone
          </Button>
        )}
      </div>
    </>
  )
}
