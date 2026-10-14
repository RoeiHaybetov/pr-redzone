import { useCallback, useEffect, useRef, useState } from 'react'
import {
  Alert, Badge, Button, CloseButton, Divider, EmptyState, Input,
  List, Meta, MetaItem, Panel, PanelBody, PanelHeader, Row, Section, Shell,
  useDeferredClose, useNuiEvent,
} from '@pr/ui'
import { post, setLocales, useConfirm, useT } from './lib'
import { DialogHost } from './admin/core'

const DIALOGS = {
  invite: (t) => ({
    title: t('squad.invite', 'Invite Player'),
    body: t('squad.invite_confirm', ''),
    input: true,
    placeholder: t('squad.invite_placeholder', 'Server ID'),
    maxLength: 6,
    payload: (value) => ({ serverId: parseInt(value, 10) }),
  }),
  rename: (t, ctx) => ({
    title: t('squad.rename', 'Rename Squad'),
    body: t('squad.rename_confirm', ''),
    input: true,
    value: ctx.name,
    placeholder: t('squad.create_placeholder', 'Squad name'),
    maxLength: 24,
    payload: (value) => ({ name: value }),
  }),
  transfer: (t, ctx) => ({
    title: t('squad.transfer', 'Transfer Leadership'),
    body: ctx.name,
    payload: () => ({ citizenid: ctx.citizenid }),
  }),
  kick: (t, ctx) => ({
    title: t('squad.kick', 'Kick Member'),
    body: ctx.name,
    danger: true,
    payload: () => ({ citizenid: ctx.citizenid }),
  }),
  leave: (t) => ({
    title: t('squad.leave_confirm', 'Leave this squad?'),
    body: t('squad.leave_warning', ''),
    danger: true,
  }),
  disband: (t) => ({
    title: t('squad.disband_confirm', 'Disband Squad?'),
    body: t('squad.disband_warning', ''),
    danger: true,
  }),
}

export default function SquadPanel() {
  const t = useT()
  const [open, setOpen] = useState(false)
  const [state, setState] = useState(null)
  const [error, setError] = useState('')
  const [createName, setCreateName] = useState('')
  const [createErr, setCreateErr] = useState('')
  const { mounted, leaving } = useDeferredClose(open)
  const confirm = useConfirm()
  const { ask, close: closeDialog, dialog } = confirm
  const openRef = useRef(false)

  useEffect(() => { openRef.current = open }, [open])

  const refresh = useCallback(async () => {
    const fresh = await post('refresh', {})
    if (fresh && fresh.ok !== false) setState(fresh)
  }, [])

  const act = useCallback(async (endpoint, payload) => {
    setError('')
    const result = await post(endpoint, payload)
    if (result && result.ok === false && result.error) setError(result.error)
    await refresh()
    return result
  }, [refresh])

  const askFor = (action, ctx) => {
    const { payload, ...opts } = DIALOGS[action](t, ctx || {})
    ask({ ...opts, onConfirm: (value) => act(action, payload ? payload(value) : {}) })
  }

  useNuiEvent('open', (data, msg) => {
    if (msg && msg.locales) setLocales(msg.locales)
    setState(data || {})
    setError('')
    setCreateErr('')
    setOpen(true)
  })

  useNuiEvent('state', (data) => setState(data || {}))

  useNuiEvent('close', () => {
    setOpen(false)
    closeDialog()
  })

  useNuiEvent('invite', () => { if (openRef.current) refresh() })
  useNuiEvent('inviteToast', () => { if (openRef.current) refresh() })
  useNuiEvent('inviteExpired', () => { if (openRef.current) refresh() })

  const close = useCallback(() => {
    setOpen(false)
    closeDialog()
    post('close', {})
  }, [closeDialog])

  useEffect(() => {
    if (!open) return undefined
    const onKey = (e) => {
      if (e.key !== 'Escape') return
      const tag = (e.target && e.target.tagName) || ''
      if (tag === 'INPUT' || tag === 'TEXTAREA') { e.target.blur(); return }
      if (dialog) { closeDialog(); return }
      close()
    }
    window.addEventListener('keyup', onKey)
    return () => window.removeEventListener('keyup', onKey)
  }, [open, dialog, closeDialog, close])

  const createSquad = async () => {
    const name = createName.trim()
    setCreateErr('')
    const result = await post('create', { name })
    if (result && result.ok === false && result.error) setCreateErr(t(result.error, result.error))
    else setCreateName('')
    await refresh()
  }

  if (!mounted) return null

  const squad = state && state.squad
  const invites = (state && state.invites) || []
  const eligible = state && state.eligible

  const inviteRows = invites.length ? (
    <List>
      {invites.map((inv) => (
        <Row
          key={inv.inviteId}
          icon="fa-envelope"
          title={inv.squadName}
          actions={(
            <>
              <Button variant="primary" onClick={() => act('respond', { inviteId: inv.inviteId, accept: true })}>
                {t('squad.accept', 'Accept')}
              </Button>
              <Button variant="ghost" onClick={() => act('respond', { inviteId: inv.inviteId, accept: false })}>
                {t('squad.decline', 'Decline')}
              </Button>
            </>
          )}
        />
      ))}
    </List>
  ) : (
    <EmptyState icon="fa-inbox" title={t('squad.invites_none', 'No pending invitations.')} />
  )

  const invitesSection = (
    <Section
      title={t('squad.invites_title', 'Pending invitations')}
      icon="fa-envelope"
      badge={<Badge count={invites.length} />}
    >
      {inviteRows}
    </Section>
  )

  const stats = squad ? [
    [t('squad.title', 'Squad'), squad.name],
    [t('squad.leader_label', 'Leader'), (squad.members || []).find((m) => m.isLeader)?.name || '—'],
    [t('squad.members_label', 'Members'), `${squad.memberCount} / ${state.maxMembers}`],
    [t('squad.session_label', 'Session'), !state.session
      ? t('squad.session_none', '—')
      : state.session.open && state.session.sessionId
        ? state.session.sessionId
        : t('squad.session_closed', 'Closed')],
    [t('squad.roster_label', 'Roster'), squad.rosterLocked
      ? t('squad.roster_locked', 'Locked')
      : t('squad.roster_unlocked', 'Open')],
    [t('squad.squad_id', 'Squad ID'), squad.id],
  ] : []

  return (
    <>
      <Shell closing={leaving}>
        <Panel width={760} height={640}>
          <PanelHeader
            title={t('squad.title', 'RedZone Squad')}
            subtitle={t('squad.subtitle', 'Solo operator squad management')}
          >
            <CloseButton onClick={close} />
          </PanelHeader>

          <Divider />

          <PanelBody>
            {!eligible ? (
              <EmptyState
                icon="fa-ban"
                title={t('squad.access_denied', 'Access denied')}
                hint={t('squad.access_denied_body', '')}
              />
            ) : !squad ? (
              <div className="rz-scrollbody rz-scrollable">
                <Section title={t('squad.no_squad_title', 'You are not in a squad')} icon="fa-user-group">
                  <span className="rz-toast-text">{t('squad.no_squad_body', '')}</span>
                  <div className="pr-field">
                    <Input
                      value={createName}
                      maxLength={24}
                      placeholder={t('squad.create_placeholder', 'Squad name')}
                      onChange={(e) => setCreateName(e.target.value)}
                      onKeyDown={(e) => { if (e.key === 'Enter') createSquad() }}
                    />
                    <Button variant="primary" disabled={!createName.trim()} onClick={createSquad}>
                      {t('squad.create', 'Create Squad')}
                    </Button>
                  </div>
                  {createErr ? <Alert>{createErr}</Alert> : null}
                </Section>

                {invitesSection}
              </div>
            ) : (
              <div className="rz-scrollbody rz-scrollable">
                {squad.rosterLocked ? (
                  <div className="rz-banner">
                    <i className="fa-solid fa-lock" />
                    <span>{t('squad.locked_banner', '')}</span>
                  </div>
                ) : null}

                <div className="rz-stats">
                  {stats.map(([label, value], i) => (
                    <div key={i} className="rz-stat-box">
                      <span>{label}</span>
                      <span title={value}>{value}</span>
                    </div>
                  ))}
                </div>

                <Section
                  title={t('squad.members_label', 'Members')}
                  icon="fa-users"
                  badge={squad.isLeader ? (
                    <div className="rz-actions-row">
                      <Button variant="primary" icon="fa-user-plus" onClick={() => askFor('invite')}>
                        {t('squad.invite', 'Invite Player')}
                      </Button>
                      <Button variant="ghost" icon="fa-pen" onClick={() => askFor('rename', squad)}>
                        {t('squad.rename', 'Rename Squad')}
                      </Button>
                    </div>
                  ) : <Badge count={squad.memberCount} />}
                >
                  <List>
                    {(squad.members || []).map((m) => (
                      <Row
                        key={m.citizenid}
                        muted={!m.inActiveRoster}
                        lead={(
                          <span
                            className={`rz-dot-online ${m.online ? 'is-on' : ''}`.trim()}
                            title={m.online ? t('squad.online', 'Online') : t('squad.offline', 'Offline')}
                          />
                        )}
                        title={m.name}
                        meta={(m.isLeader || (squad.rosterLocked && !m.inActiveRoster)) ? (
                          <Meta>
                            {m.isLeader ? <MetaItem icon="fa-crown">{t('squad.leader', 'Leader')}</MetaItem> : null}
                            {squad.rosterLocked && !m.inActiveRoster
                              ? <MetaItem icon="fa-hourglass-half">{t('squad.pending_next_session', 'Next session')}</MetaItem>
                              : null}
                          </Meta>
                        ) : null}
                        actions={squad.isLeader && !m.isLeader ? (
                          <>
                            <Button variant="ghost" onClick={() => askFor('transfer', m)}>
                              {t('squad.transfer', 'Transfer')}
                            </Button>
                            <Button variant="danger" onClick={() => askFor('kick', m)}>
                              {t('squad.kick', 'Kick')}
                            </Button>
                          </>
                        ) : null}
                      />
                    ))}
                  </List>
                </Section>

                {invitesSection}

                <div className="rz-actions-row">
                  {!squad.isLeader || squad.memberCount === 1 ? (
                    <Button variant="ghost" icon="fa-right-from-bracket" onClick={() => askFor('leave')}>
                      {t('squad.leave', 'Leave Squad')}
                    </Button>
                  ) : null}

                  {squad.isLeader ? (
                    <Button variant="danger" icon="fa-trash" onClick={() => askFor('disband')}>
                      {t('squad.disband', 'Disband Squad')}
                    </Button>
                  ) : null}
                </div>
              </div>
            )}

            {error ? <Alert>{t(error, error)}</Alert> : null}
          </PanelBody>
        </Panel>
      </Shell>

      <DialogHost
        confirm={confirm}
        cancelLabel={t('squad.cancel', 'Cancel')}
        confirmLabel={t('squad.confirm', 'Confirm')}
      />
    </>
  )
}

export { SquadPanel }
