import { Badge, Button, EmptyState, ExpandableRow, Meta, MetaItem, Row, Section, SparkLoader } from '@pr/ui'
import { post, useAsync } from '../../lib'
import { useAdmin, StatLine } from '../core'

const MAINTENANCE = [
  ['Rebuild everything', 'rebuild_all', true],
  ['Revalidate all players', 'revalidate_all', false],
  ['Prune expired cooldowns', 'cooldown_prune', false],
  ['Apply queued change now', 'flush_deferred', true],
  ['Discard queued change', 'cancel_deferred', true],
]

const COLUMNS = ['ID', 'Name', 'State', 'Zone', 'Group', 'Eligible', 'Reason', 'Cooldown', '']

export default function Overview() {
  const { cfg, notify, ask, reload } = useAdmin()
  const { data: live } = useAsync('rzAdminDashboard')
  const { data: diag } = useAsync('rzAdminDiagnostics')
  const { data: insp } = useAsync('rzAdminInspect')

  const stats = live ? live.data : null
  const checks = diag && diag.data ? diag.data.checks || [] : null
  const rows = insp ? insp.rows || [] : []

  // The server reports 'ok' | 'warning' | 'error' | 'na'.
  const failing = checks ? checks.filter((c) => c.status === 'error').length : 0
  const health = diag === undefined ? 'Running diagnostics…'
    : !checks ? 'Diagnostics unavailable.'
      : failing ? `${failing} check${failing === 1 ? '' : 's'} failing`
        : `All ${checks.length} checks passing`

  const groups = {}
  if (checks) {
    checks.forEach((c) => {
      const name = c.group || 'General'
      if (!groups[name]) groups[name] = []
      groups[name].push(c)
    })
  }

  const run = (action, payload, destructive, label) => {
    const go = async () => {
      const res = await post('rzAdminControl', { action, payload })
      notify(res.message || res.error || (res.ok ? 'Done.' : 'Failed.'), !res.ok)
      if (res.ok) await reload()
    }

    if (!destructive) { go(); return }

    ask({
      title: 'Confirm',
      body: `${label}. This affects the live server immediately.`,
      confirmLabel: 'Do it',
      danger: true,
      onConfirm: go,
    })
  }

  const revalidate = async (source) => {
    const res = await post('rzAdminControl', { action: 'revalidate_player', payload: { target: source } })
    notify(res.message || res.error || '', !res.ok)
  }

  const setWebhook = async (url, done) => {
    const res = await post('rzAdminSetWebhook', { url })
    if (!res.ok) return { error: res.error || 'Failed.' }
    notify(done)
    await reload()
    return null
  }

  return (
    <>
      {live === undefined ? <EmptyState><SparkLoader /></EmptyState> : null}
      {live !== undefined && !stats ? <EmptyState icon="fa-plug-circle-xmark" title="Could not load live state." /> : null}

      {stats ? (
        <div className="rz-cards">
          <Section title="System" icon="fa-server">
            <StatLine label="Server time" value={`${stats.serverTime} ${stats.utcOffset || ''}`.trim()} />
            <StatLine label="Revision" value={stats.revision} />
            <StatLine label="Schema" value={`v${stats.schemaVersion}`} />
            <StatLine label="Debug mode" value={stats.debug ? 'ON' : 'off'} />
            <StatLine label="Forced open" value={stats.forcedOpen ? 'YES' : 'no'} />
            <StatLine label="Config state" value={stats.degraded ? 'DEGRADED' : 'healthy'} />
            <StatLine label="Admin sessions" value={stats.totals ? stats.totals.adminSessions : '—'} />
            <StatLine label="Queued change" value={stats.deferred ? 'yes (next session)' : 'none'} />
          </Section>

          {(stats.zones || []).map((z) => (
            <Section
              key={z.id}
              title={z.label || z.id}
              icon="fa-location-dot"
              badge={<Badge>{z.enabled ? (z.open ? 'open' : 'closed') : 'disabled'}</Badge>}
            >
              {z.enabled ? (
                <>
                  <StatLine label="Session" value={z.sessionId || '—'} />
                  <StatLine label="Players inside" value={z.players} />
                  <StatLine label="Alive groups" value={z.aliveGroups} />
                  <StatLine label="Eliminated" value={z.eliminated} />
                  <StatLine label="Blocked" value={z.blocked} />
                  <StatLine label="Crate" value={z.crateActive ? 'ACTIVE' : (z.crateRunning ? 'counting down' : 'paused')} />
                  <StatLine label="Next crate" value={`${Math.ceil((z.crateRemainingMs || 0) / 1000)}s`} />
                  <StatLine label="Override" value={z.override ? z.override.state : 'schedule'} />
                </>
              ) : null}
            </Section>
          ))}
        </div>
      ) : null}

      <ExpandableRow
        icon={failing ? 'fa-triangle-exclamation' : 'fa-heart-pulse'}
        title="Health checks"
        meta={(
          <Meta>
            <MetaItem icon="fa-stethoscope">{health}</MetaItem>
            {failing ? <Badge count={failing}>failing</Badge> : null}
          </Meta>
        )}
      >
        {diag === undefined ? <SparkLoader /> : null}
        {diag !== undefined && !checks ? <EmptyState icon="fa-plug-circle-xmark" title="Diagnostics unavailable." /> : null}
        {Object.keys(groups).map((name) => (
          <Section key={name} title={name} icon="fa-stethoscope">
            {groups[name].map((c, i) => (
              <div key={i} className="rz-check">
                <div className={`rz-dot ${c.status || ''}`.trim()} />
                <div className="rz-check-body">
                  <strong>{c.label}</strong>
                  {c.detail ? <p>{c.detail}</p> : null}
                </div>
              </div>
            ))}
          </Section>
        ))}
      </ExpandableRow>

      <ExpandableRow
        icon="fa-users-viewfinder"
        title="Players"
        meta={(
          <Meta>
            <MetaItem icon="fa-user">
              {insp === undefined ? 'Loading…' : `${rows.length} player${rows.length === 1 ? '' : 's'} tracked`}
            </MetaItem>
          </Meta>
        )}
      >
        {rows.length ? (
          <div className="rz-scroll rz-scrollable">
            <table className="rz-table">
              <thead>
                <tr>{COLUMNS.map((h, i) => <th key={i}>{h}</th>)}</tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.source}>
                    <td className="rz-num">{row.source}</td>
                    <td>{row.name}</td>
                    <td>{row.state}</td>
                    <td>{row.zoneId || '—'}</td>
                    <td>{row.group}</td>
                    <td>{row.eligible ? 'yes' : 'no'}</td>
                    <td>{row.reason || '—'}</td>
                    <td className="rz-num">{row.cooldownMs > 0 ? `${Math.ceil(row.cooldownMs / 60000)}m` : '—'}</td>
                    <td><Button variant="ghost" onClick={() => revalidate(row.source)}>Revalidate</Button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState icon="fa-user-slash" title="Nobody is being tracked right now." />
        )}
      </ExpandableRow>

      <Section title="Maintenance" icon="fa-screwdriver-wrench">
        <div className="rz-actions-row">
          {MAINTENANCE.map(([label, action, destructive]) => (
            <Button
              key={action}
              variant={destructive ? 'danger' : 'ghost'}
              onClick={() => run(action, {}, destructive, label)}
            >
              {label}
            </Button>
          ))}
        </div>
      </Section>

      <Section title="Discord webhook" icon="fa-comment-dots">
        <Row
          icon={cfg.webhookConfigured ? 'fa-link' : 'fa-link-slash'}
          title={cfg.webhookConfigured ? 'Configured' : 'Not configured'}
          meta={(
            <Meta>
              <MetaItem icon="fa-shield-halved">The current URL is never sent to this interface.</MetaItem>
            </Meta>
          )}
          actions={(
            <>
              {cfg.capabilities.allowWebhookReplacement ? (
                <>
                  <Button
                    variant="ghost"
                    onClick={() => ask({
                      title: 'Replace Discord webhook',
                      body: 'Paste the new webhook URL. It is stored server-side and never shown again.',
                      input: true,
                      placeholder: 'https://discord.com/api/webhooks/...',
                      confirmLabel: 'Save webhook',
                      onConfirm: (url) => setWebhook(url, 'Webhook updated.'),
                    })}
                  >
                    Replace
                  </Button>
                  <Button
                    variant="danger"
                    onClick={() => ask({
                      title: 'Clear the webhook?',
                      body: 'Discord logging will stop. Other logging is unaffected.',
                      confirmLabel: 'Clear',
                      danger: true,
                      onConfirm: () => setWebhook('', 'Webhook cleared.'),
                    })}
                  >
                    Clear
                  </Button>
                </>
              ) : null}

              <Button
                variant="ghost"
                onClick={async () => {
                  const res = await post('rzAdminTestLog', {})
                  notify(res.ok ? 'Test log sent.' : 'Failed to send.', !res.ok)
                }}
              >
                Send test log
              </Button>
            </>
          )}
        />
      </Section>
    </>
  )
}
