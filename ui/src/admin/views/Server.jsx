import { Button, EmptyState, ExpandableRow, Meta, MetaItem, Section, SparkLoader } from '@pr/ui'
import { post, useAsync } from '../../lib'
import { useAdmin, DiffItem } from '../core'
import Settings from './Settings'

const HISTORY_QUERY = { limit: 30 }

function History() {
  const { notify, setValue, setZones, setActive } = useAdmin()
  const { data } = useAsync('rzAdminHistory', HISTORY_QUERY)

  if (data === undefined) return <SparkLoader />

  if (data === null) return <EmptyState icon="fa-plug-circle-xmark" title="Could not load configuration history." />

  const rows = data.rows || []
  if (!rows.length) return <EmptyState icon="fa-clock-rotate-left" title="No configuration history yet." />

  const restore = async (revision) => {
    const r = await post('rzAdminLoadRevision', { revision })
    if (!r.ok) return notify(r.error || 'Could not load that revision.', true)

    const draft = r.draft || {}
    const fields = draft.fields || {}
    Object.keys(fields).forEach((p) => setValue(p, fields[p]))
    if (draft.zones) setZones(draft.zones)

    const dropped = draft.dropped || []
    notify(dropped.length
      ? `Loaded. ${dropped.length} obsolete setting(s) were ignored.`
      : 'Revision loaded as a draft. Review and publish to roll back.')

    setActive('overview')
  }

  return (
    <>
      {rows.map((row) => (
        <Section
          key={row.revision}
          title={`Revision ${row.revision}`}
          icon="fa-code-commit"
          badge={(
            <Button variant="ghost" icon="fa-rotate-left" onClick={() => restore(row.revision)}>
              Restore as draft
            </Button>
          )}
        >
          <div className="rz-field-desc">
            {`${row.createdAt} — ${row.by || 'unknown'} (${row.byDiscord}) — ${row.fieldCount} field(s)`}
            {row.reason ? ` — “${row.reason}”` : ''}
          </div>

          {row.diff && row.diff.length ? (
            <div className="rz-diff">
              {row.diff.slice(0, 12).map((item, i) => <DiffItem key={i} item={item} />)}
            </div>
          ) : null}
        </Section>
      ))}
    </>
  )
}

function Exchange() {
  const { cfg, notify, ask, setValue, setZones } = useAdmin()

  const generate = async () => {
    const r = await post('rzAdminExport', {})
    if (!r.ok) return notify('Export failed.', true)
    ask({
      title: 'Configuration export',
      body: 'Copy this JSON. Secrets are excluded.',
      textarea: JSON.stringify(r.payload, null, 2),
      wide: true,
      confirmLabel: 'Close',
      onConfirm: () => null,
    })
  }

  const load = () => ask({
    title: 'Import configuration',
    body: 'Paste exported JSON. It becomes a DRAFT — nothing is applied until you publish.',
    textarea: '',
    editable: true,
    wide: true,
    confirmLabel: 'Load as draft',
    onConfirm: (text) => {
      let parsed
      try { parsed = JSON.parse(text) } catch { return { error: 'That is not valid JSON.' } }

      if (!parsed || typeof parsed !== 'object' || typeof parsed.fields !== 'object') {
        return { error: 'Missing a "fields" object.' }
      }
      if (Number(parsed.schemaVersion) > Number(cfg.schemaVersion || 1)) {
        return { error: 'That export was made by a newer version of the resource.' }
      }

      let loaded = 0
      let skipped = 0
      Object.keys(parsed.fields).forEach((p) => {
        if (cfg.fields.some((f) => f.path === p)) { setValue(p, parsed.fields[p]); loaded++ }
        else skipped++
      })

      let zoneNote = ''
      if (parsed.zones && typeof parsed.zones === 'object') {
        setZones(parsed.zones)
        zoneNote = ', including zone geometry'
      }

      notify(`Imported ${loaded} setting(s)${skipped ? `, ignored ${skipped} unknown` : ''}${zoneNote}. Review and publish.`)
      return null
    },
  })

  return (
    <div className="rz-actions-row">
      <Button variant="ghost" icon="fa-file-export" onClick={generate}>Generate export</Button>
      <Button variant="ghost" icon="fa-file-import" onClick={load}>Import into draft</Button>
    </div>
  )
}

export default function Server({ section }) {
  return (
    <>
      <Settings section={section} />

      <ExpandableRow
        icon="fa-clock-rotate-left"
        title="History & rollback"
        meta={(
          <Meta>
            <MetaItem icon="fa-code-commit">Restore any published revision as a draft.</MetaItem>
          </Meta>
        )}
      >
        <History />
      </ExpandableRow>

      <ExpandableRow
        icon="fa-right-left"
        title="Import & export"
        meta={(
          <Meta>
            <MetaItem icon="fa-shield-halved">Secrets and the admin whitelist are excluded.</MetaItem>
          </Meta>
        )}
      >
        <Exchange />
      </ExpandableRow>
    </>
  )
}
