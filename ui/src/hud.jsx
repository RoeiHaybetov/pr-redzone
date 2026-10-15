import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, useDeferredClose, useNuiEvent } from '@pr/ui'
import { post, setLocales, useT } from './lib'

const POSITIONS = [
  'bottom-right', 'bottom-left', 'bottom-center',
  'top-right', 'top-left', 'top-center',
]

const clamp = (n, lo, hi) => Math.min(hi, Math.max(lo, n))

function clock(ms) {
  const total = Math.max(0, Math.floor(ms / 1000))
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
}

function write(cache, key, value, target, prop) {
  if (!target || cache[key] === value) return
  cache[key] = value
  target[prop] = value
}

function useMirror(value) {
  const ref = useRef(value)
  useEffect(() => { ref.current = value }, [value])
  return ref
}

function useTicker(active, tick) {
  const saved = useRef(tick)
  useEffect(() => { saved.current = tick })

  useEffect(() => {
    if (!active) return undefined

    const cache = {}
    let frame = 0
    const loop = () => {
      saved.current(cache)
      frame = requestAnimationFrame(loop)
    }

    frame = requestAnimationFrame(loop)
    return () => cancelAnimationFrame(frame)
  }, [active])
}

export function CrateHud() {
  const [hud, setHud] = useState(null)
  const timeRef = useRef(null)
  const fillRef = useRef(null)
  const hudRef = useMirror(hud)

  useNuiEvent('rzCrate', (data) => {
    const d = data || {}
    if (!d.visible) {
      setHud(null)
      return
    }
    setHud((prev) => ({
      status: d.status || 'empty',
      remainingMs: d.remainingMs || 0,
      intervalMs: d.intervalMs || 300000,
      labels: d.labels || (prev && prev.labels) || {},
      position: d.position || (prev && prev.position) || 'bottom-right',
      scale: d.scale || (prev && prev.scale) || 1,
      at: performance.now(),
    }))
  })

  useTicker(hud !== null, (cache) => {
    const c = hudRef.current
    if (!c) return

    const elapsed = c.status === 'running' ? performance.now() - c.at : 0
    const remaining = Math.max(0, c.remainingMs - elapsed)
    const pct = c.status === 'active'
      ? 100
      : c.intervalMs > 0 ? clamp((1 - remaining / c.intervalMs) * 100, 0, 100) : 0

    write(cache, 'time', clock(remaining), timeRef.current, 'textContent')
    write(cache, 'width', `${pct.toFixed(2)}%`, fillRef.current && fillRef.current.style, 'width')
  })

  if (!hud) return null

  const position = POSITIONS.includes(hud.position) ? hud.position : 'bottom-right'
  const scale = Number(hud.scale) > 0 ? Number(hud.scale) : 1

  return (
    <div className={`rz-crate pos-${position} is-${hud.status}`} style={{ '--rz-scale': scale }}>
      <div className="rz-crate-bar"><span ref={fillRef} style={{ width: 0 }} /></div>
      <div className="rz-crate-body">
        <span className="rz-crate-title">
          <i className="fa-solid fa-box-open" />
          {hud.labels.title || 'REDZONE'}
        </span>
        {hud.status === 'active' ? null : (
          <span ref={timeRef} className="rz-crate-time rz-num">0:00</span>
        )}
        <span className="rz-crate-status">{hud.labels[hud.status] || ''}</span>
      </div>
    </div>
  )
}

export function InviteToast() {
  const t = useT()
  const [invite, setInvite] = useState(null)
  const { mounted, leaving } = useDeferredClose(invite !== null)
  const barRef = useRef(null)
  const timerRef = useRef(0)
  const lastRef = useRef(null)

  const dismiss = useCallback(() => {
    clearTimeout(timerRef.current)
    setInvite(null)
  }, [])

  const receive = useCallback((data, msg, interactive) => {
    if (msg && msg.locales) setLocales(msg.locales)
    if (!data || typeof data.inviteId !== 'string') return
    lastRef.current = { ...data, interactive }
    setInvite({ ...data, interactive, at: Date.now() })
  }, [])

  // inviteToast is only sent while the squad panel is closed, so the toast has no focus to click with.
  useNuiEvent('invite', (data, msg) => receive(data, msg, true))
  useNuiEvent('inviteToast', (data, msg) => receive(data, msg, false))

  useNuiEvent('inviteExpired', (data) => {
    if (lastRef.current && data && lastRef.current.inviteId === data.inviteId) dismiss()
  })

  useEffect(() => {
    if (!invite || !mounted) return undefined

    const ms = invite.expiresInMs || 30000
    const bar = barRef.current

    if (bar) {
      bar.style.transition = 'none'
      bar.style.width = '100%'
      void bar.offsetWidth
      bar.style.transition = `width ${ms}ms linear`
      bar.style.width = '0%'
    }

    clearTimeout(timerRef.current)
    timerRef.current = setTimeout(dismiss, ms)
    return () => clearTimeout(timerRef.current)
  }, [invite, mounted, dismiss])

  const respond = (accept) => {
    const current = lastRef.current
    dismiss()
    if (current) post('respond', { inviteId: current.inviteId, accept })
  }

  if (!mounted) return null

  const current = invite || lastRef.current || {}
  const squadName = current.squadName || '?'

  return (
    <div className={`rz-toast ${leaving ? 'is-leaving' : ''}`.trim()}>
      <div className="rz-toast-body">
        <span className="rz-toast-head">
          <i className="fa-solid fa-user-plus" />
          {t('squad.invite_received_title', 'RedZone Squad Invitation')}
        </span>

        <span className="rz-toast-text">
          {t('squad.invite_received_body', 'You were invited to %s.').replace('%s', squadName)}
        </span>

        {current.interactive ? (
          <div className="rz-toast-actions">
            <Button variant="primary" onClick={() => respond(true)}>
              {t('squad.accept', 'Accept')}
            </Button>
            <Button variant="ghost" onClick={() => respond(false)}>
              {t('squad.decline', 'Decline')}
            </Button>
          </div>
        ) : (
          <span className="rz-toast-text">
            {t('squad.invite_open_hint', 'Open /rzsquad to accept or decline.')}
          </span>
        )}
      </div>

      <div className="rz-toast-timer"><span ref={barRef} /></div>
    </div>
  )
}
