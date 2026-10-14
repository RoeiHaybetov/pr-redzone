import { useEffect, useMemo, useState } from 'react'
import {
  Badge, Button, EmptyState, ExpandableRow, IconButton, Input, Meta, MetaItem,
  Section, Select, Switch,
} from '@pr/ui'
import { post } from '../lib'
import { ApplyChip, clone, useAdmin } from './core'

const EMPTY_LIST = []
const EMPTY_MAP = {}

const SUGGEST = {
  'BlockedJobs.types': 'jobTypes',
  'BlockedJobs.names': 'jobNames',
}

const LIMIT_KEYS = [['max', 1], ['windowMs', 500]]

function NumberInput({ value, min, max, step, onCommit, className = '' }) {
  const [text, setText] = useState(String(value ?? ''))
  const [bad, setBad] = useState(false)

  useEffect(() => {
    setText(String(value ?? ''))
    setBad(false)
  }, [value])

  return (
    <Input
      type="number" value={text} min={min} max={max} step={step}
      className={`${className} ${bad ? 'is-bad' : ''}`.trim()}
      onChange={(e) => setText(e.target.value)}
      onBlur={() => {
        const n = Number(text)
        if (!isFinite(n) || text === '') { setBad(true); return }
        setBad(false)
        onCommit(n)
      }}
      onKeyDown={(e) => { if (e.key === 'Enter') e.target.blur() }}
    />
  )
}

function useEditor(f, fallback) {
  const { valueOf, setValue } = useAdmin()
  const raw = valueOf(f.path)
  const usable = Array.isArray(fallback) ? Array.isArray(raw) : !!raw && typeof raw === 'object'
  const value = usable ? raw : fallback

  const edit = (mutate) => {
    const next = clone(value)
    mutate(next)
    setValue(f.path, next)
  }

  return [value, edit]
}

function BoolField({ f }) {
  const { valueOf, setValue } = useAdmin()
  return <Switch checked={!!valueOf(f.path)} onChange={() => setValue(f.path, !valueOf(f.path))} />
}

function NumberField({ f }) {
  const { valueOf, setValue } = useAdmin()
  return (
    <>
      <NumberInput
        value={valueOf(f.path)} min={f.min} max={f.max} step={f.step} className="rz-row-num"
        onCommit={(n) => setValue(f.path, f.type === 'int' ? Math.round(n) : n)}
      />
      {f.unit ? <span className="rz-row-key" style={{ flex: '0 0 auto' }}>{f.unit}</span> : null}
    </>
  )
}

function StringField({ f }) {
  const { valueOf, setValue, notify } = useAdmin()
  const current = String(valueOf(f.path) ?? '')
  const [text, setText] = useState(current)

  useEffect(() => { setText(current) }, [current])

  const validateModel = async () => {
    const r = await post('rzAdminValidateModel', { model: valueOf(f.path), expect: f.modelCheck })
    if (!r.ok) return notify(r.error || 'Model failed to load.', true)
    if (r.mismatch) {
      return notify(`Loads, but it is ${r.isPed ? 'a ped' : 'an object'} — expected ${f.modelCheck}.`, true)
    }
    notify('Model loads correctly.')
  }

  const preview = async () => {
    const pos = await post('rzAdminGetPosition', {})
    if (!pos.ok) return
    const r = await post('rzAdminPreview', { key: 'field', model: valueOf(f.path), kind: f.modelCheck, coords: pos.coords })
    notify(r.ok ? 'Preview spawned at your position.' : (r.error || 'Preview failed.'), !r.ok)
  }

  return (
    <>
      <Input
        value={text}
        maxLength={f.maxLength}
        onChange={(e) => setText(e.target.value)}
        onBlur={() => setValue(f.path, text)}
        onKeyDown={(e) => { if (e.key === 'Enter') e.target.blur() }}
      />
      {f.modelCheck ? (
        <>
          <Button variant="ghost" icon="fa-circle-check" onClick={validateModel}>Validate</Button>
          <Button variant="ghost" icon="fa-eye" onClick={preview}>Preview</Button>
        </>
      ) : null}
    </>
  )
}

function SelectField({ f }) {
  const { valueOf, setValue } = useAdmin()
  return (
    <Select
      dense
      value={valueOf(f.path)}
      options={(f.options || []).map((o) => ({ value: o, label: String(o) }))}
      onChange={(v) => setValue(f.path, v)}
    />
  )
}

function VectorField({ f }) {
  const { cfg, valueOf, setValue, notify } = useAdmin()
  const keys = f.type === 'vec4' ? ['x', 'y', 'z', 'w'] : ['x', 'y', 'z']
  const v = valueOf(f.path) || {}

  const commit = (key, n) => {
    const next = clone(valueOf(f.path)) || {}
    next[key] = n
    keys.forEach((k) => { if (next[k] === undefined) next[k] = 0 })
    setValue(f.path, next)
  }

  const useMyPosition = async () => {
    const pos = await post('rzAdminGetPosition', {})
    if (!pos.ok) return
    const next = { x: pos.coords.x, y: pos.coords.y, z: pos.coords.z }
    if (f.type === 'vec4') next.w = pos.coords.w
    setValue(f.path, next)
    notify('Captured your current position.')
  }

  const placeInWorld = () => {
    const modelField = cfg.fields.find((x) =>
      x.zoneId === f.zoneId
      && x.stationIndex === f.stationIndex
      && (x.modelCheck === 'prop' || x.modelCheck === 'ped')
      && x.group === f.group)

    const model = modelField ? valueOf(modelField.path) : null
    post('rzAdminPlacement', { path: f.path, kind: f.placement, model, coords: valueOf(f.path) })
  }

  return (
    <>
      {keys.map((k) => (
        <NumberInput key={k} value={v[k] ?? 0} step="0.0001" className="rz-row-num" onCommit={(n) => commit(k, n)} />
      ))}
      <Button variant="ghost" icon="fa-location-crosshairs" onClick={useMyPosition}>Use my position</Button>
      <Button variant="ghost" icon="fa-plane-arrival" onClick={() => post('rzAdminTeleport', { coords: valueOf(f.path) })}>
        Teleport
      </Button>
      {f.placement ? (
        <Button variant="ghost" icon="fa-hand-pointer" onClick={placeInWorld}>Place in world</Button>
      ) : null}
    </>
  )
}

function TagsField({ f }) {
  const { cfg } = useAdmin()
  const [list, edit] = useEditor(f, EMPTY_LIST)
  const [text, setText] = useState('')

  const known = Object.keys(SUGGEST).find((p) => f.path.includes(p))
  const suggestions = known ? cfg.suggestions[SUGGEST[known]] : null
  const listId = suggestions && suggestions.length ? `dl-${f.path.replace(/[^\w]/g, '-')}` : undefined

  const add = () => {
    const value = text.trim()
    if (!value) return
    edit((next) => { if (!next.includes(value)) next.push(value) })
    setText('')
  }

  return (
    <div className="rz-tags">
      {list.map((tag, idx) => (
        <span key={`${tag}-${idx}`} className="rz-tag">
          <span>{tag}</span>
          <IconButton icon="fa-xmark" size="sm" tone="danger" onClick={() => edit((next) => next.splice(idx, 1))} />
        </span>
      ))}

      {listId ? (
        <datalist id={listId}>
          {suggestions.map((s) => <option key={s} value={s} />)}
        </datalist>
      ) : null}

      <Input
        list={listId} value={text} placeholder="add…" maxLength={f.maxLength}
        style={{ maxWidth: 150 }}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); add() } }}
      />
    </div>
  )
}

function RewardsField({ f }) {
  const [list, edit] = useEditor(f, EMPTY_LIST)

  return (
    <div className="rz-rows">
      {list.map((row, idx) => (
        <div key={idx} className="rz-row">
          <Input
            value={row.item ?? ''}
            placeholder="item name"
            onChange={(e) => {
              const value = e.target.value.trim()
              edit((next) => { next[idx].item = value })
            }}
          />
          <NumberInput
            value={row.amount ?? 1} min={1} className="rz-row-num"
            onCommit={(n) => edit((next) => { next[idx].amount = Math.max(1, Math.round(n)) })}
          />
          <IconButton icon="fa-trash" tone="danger" onClick={() => edit((next) => next.splice(idx, 1))} />
        </div>
      ))}

      <Button variant="ghost" icon="fa-plus" onClick={() => edit((next) => next.push({ item: '', amount: 1 }))}>
        Add reward
      </Button>
    </div>
  )
}

function RateLimitsField({ f }) {
  const [map, edit] = useEditor(f, EMPTY_MAP)

  return (
    <div className="rz-rows">
      {Object.keys(map).sort().map((action) => (
        <div key={action} className="rz-row">
          <span className="rz-row-key">{action}</span>
          {LIMIT_KEYS.map(([key, min]) => (
            <NumberInput
              key={key} value={map[action][key]} min={min} step={min === 1 ? undefined : min} className="rz-row-num"
              onCommit={(n) => edit((next) => { next[action][key] = Math.max(min, Math.round(n)) })}
            />
          ))}
        </div>
      ))}
    </div>
  )
}

function BoolMapField({ f }) {
  const [map, edit] = useEditor(f, EMPTY_MAP)

  return (
    <div className="rz-tags">
      {Object.keys(map).sort().map((key) => (
        <span key={key} className="rz-tag">
          <span>{key}</span>
          <Switch checked={!!map[key]} onChange={() => edit((next) => { next[key] = !next[key] })} />
        </span>
      ))}
    </div>
  )
}

const BUILDERS = {
  bool: BoolField,
  number: NumberField,
  int: NumberField,
  string: StringField,
  select: SelectField,
  vec3: VectorField,
  vec4: VectorField,
  tags: TagsField,
  clipsets: TagsField,
  rewards: RewardsField,
  ratelimits: RateLimitsField,
  boolmap: BoolMapField,
}

const NO_CHIP = new Set(['rewards', 'ratelimits', 'boolmap'])

export function Field({ f }) {
  const { isChanged, resetPath, fieldErrors } = useAdmin()
  const Builder = BUILDERS[f.type]
  const changed = isChanged(f.path)
  const error = fieldErrors[f.path]

  return (
    <div className={`rz-field ${changed ? 'is-changed' : ''}`.trim()}>
      <div className="rz-field-label">
        <label>{f.label}</label>
        {f.desc ? <div className="rz-field-desc">{f.desc}</div> : null}
        {f.danger ? <div className="rz-field-desc is-danger">Dangerous setting</div> : null}
      </div>

      <div className="rz-field-input">
        {Builder ? <Builder f={f} /> : <span className="rz-row-key">unsupported type: {f.type}</span>}
        {NO_CHIP.has(f.type) ? null : <ApplyChip mode={f.apply} />}
        {changed ? (
          <Button variant="ghost" icon="fa-rotate-left" onClick={() => resetPath(f.path)}>Reset</Button>
        ) : null}
      </div>

      {error ? <div className="rz-field-err">{error}</div> : null}
    </div>
  )
}

function GroupBlock({ name, fields }) {
  return (
    <Section title={name} icon="fa-sliders">
      {fields.map((f) => <Field key={f.path} f={f} />)}
    </Section>
  )
}

export function Groups({ fields = [], expanded = false, empty = 'No settings in this section.' }) {
  const { isChanged } = useAdmin()

  const [plain, advanced] = useMemo(() => {
    const order = []
    const byName = new Map()

    fields.forEach((f) => {
      const name = f.group || 'General'
      if (!byName.has(name)) {
        byName.set(name, { open: [], folded: [] })
        order.push(name)
      }
      const bucket = byName.get(name)
      if (f.advanced && !expanded) bucket.folded.push(f)
      else bucket.open.push(f)
    })

    const open = []
    const folded = []

    order.forEach((name) => {
      const bucket = byName.get(name)
      if (bucket.open.length) open.push([name, bucket.open])
      if (bucket.folded.length) folded.push([name, bucket.folded])
    })

    return [open, folded]
  }, [fields, expanded])

  if (!fields.length) return <EmptyState icon="fa-magnifying-glass" title={empty} />

  const hiddenFields = advanced.reduce((n, [, list]) => n + list.length, 0)
  const hiddenChanges = advanced.reduce((n, [, list]) => n + list.filter((f) => isChanged(f.path)).length, 0)

  return (
    <>
      {plain.map(([name, list]) => <GroupBlock key={name} name={name} fields={list} />)}

      {advanced.length ? (
        <ExpandableRow
          title="Advanced"
          icon="fa-screwdriver-wrench"
          defaultOpen={hiddenChanges > 0}
          meta={<Meta><MetaItem icon="fa-layer-group">{hiddenFields} setting(s)</MetaItem></Meta>}
          actions={hiddenChanges > 0 ? <Badge count={hiddenChanges}>changed</Badge> : null}
        >
          {advanced.map(([name, list]) => <GroupBlock key={name} name={name} fields={list} />)}
        </ExpandableRow>
      ) : null}
    </>
  )
}

export default Field
