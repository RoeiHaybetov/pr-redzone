import { useCallback, useEffect, useRef, useState } from 'react'
import { Button, useDeferredClose, useNuiEvent } from '@pr/ui'
import { post, setLocales, useT } from './lib'

const POSITIONS = [
  'bottom-right', 'bottom-left', 'bottom-center',
  'top-right', 'top-left', 'top-center',
]

const CIRCUMFERENCE = 326.7

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

export function KnockHud() {
  const [hud, setHud] = useState(null)
  const [critical, setCritical] = useState(false)
  const timeRef = useRef(null)
  const ringRef = useRef(null)
  const hudRef = useMirror(hud)

  useNuiEvent('rzKnock', (data) => {
    const d = data || {}
    if (!d.visible) {
      setHud(null)
      setCritical(false)
      return
    }
    setHud((prev) => ({
      remainingMs: d.remainingMs || 0,
      durationMs: d.durationMs || 30000,
      paused: !!d.paused,
      labels: d.labels || (prev && prev.labels) || {},
      at: performance.now(),
    }))
  })

  useTicker(hud !== null, (cache) => {
    const k = hudRef.current
    if (!k) return

    const elapsed = k.paused ? 0 : performance.now() - k.at
    const remaining = Math.max(0, k.remainingMs - elapsed)
    const frac = k.durationMs > 0 ? clamp(remaining / k.durationMs, 0, 1) : 0

    write(cache, 'seconds', Math.ceil(remaining / 1000), timeRef.current, 'textContent')
    write(cache, 'offset', (CIRCUMFERENCE * (1 - frac)).toFixed(1),
      ringRef.current && ringRef.current.style, 'strokeDashoffset')

    const isCritical = !k.paused && remaining <= 5000
    if (isCritical !== cache.critical) {
      cache.critical = isCritical
      setCritical(isCritical)
    }
  })

  if (!hud) return null

  const cls = ['rz-knock', hud.paused ? 'is-paused' : '', critical ? 'is-critical' : '']
    .filter(Boolean).join(' ')

  return (
    <div className={cls}>
      <svg className="rz-ring" viewBox="0 0 120 120">
        <circle className="rz-ring-track" cx="60" cy="60" r="52" />
        <circle ref={ringRef} className="rz-ring-fill" cx="60" cy="60" r="52" />
      </svg>

      <div className="rz-knock-center">
        <span ref={timeRef} className="rz-knock-time rz-num">0</span>
        <span className="rz-knock-unit">SEC</span>
      </div>

      <div className="rz-knock-label">
        <span className="rz-knock-title">
          <i className={`fa-solid ${hud.paused ? 'fa-hand-holding-medical' : 'fa-heart-crack'}`} />
          {hud.paused
            ? (hud.labels.paused || 'BEING REVIVED')
            : (hud.labels.title || 'BLEEDING OUT')}
        </span>
        {hud.paused ? null : <span className="rz-knock-hint">{hud.labels.hint || ''}</span>}
      </div>
    </div>
  )
}

export function CprHud() {
  const [run, setRun] = useState(null)
  const [beat, setBeat] = useState({ grade: '', hits: 0, misses: 0, streak: 0 })
  const stageRef = useRef(null)
  const heartRef = useRef(null)
  const approachRef = useRef(null)
  const flashRef = useRef(0)
  const runRef = useMirror(run)

  useNuiEvent('rzCpr', (data) => {
    const d = data || {}
    if (!d.visible) {
      setRun(null)
      return
    }
    setRun({
      startedAt: performance.now(),
      beatIntervalMs: d.beatIntervalMs || 545,
      totalBeats: d.totalBeats || 0,
      requiredAccuracy: d.requiredAccuracy ?? 0.6,
    })
    setBeat({ grade: '', hits: 0, misses: 0, streak: 0 })
  })

  useNuiEvent('rzCprBeat', (data) => {
    const d = data || {}
    setBeat({
      grade: d.grade || 'miss',
      hits: d.hits || 0,
      misses: d.misses || 0,
      streak: d.streak || 0,
    })

    const stage = stageRef.current
    if (!stage) return

    const good = d.grade === 'perfect' || d.grade === 'good' || d.grade === 'late'
    stage.classList.remove('hit', 'bad')
    void stage.offsetWidth
    stage.classList.add(good ? 'hit' : 'bad')

    clearTimeout(flashRef.current)
    flashRef.current = setTimeout(() => stage.classList.remove('hit', 'bad'), 140)
  })

  useEffect(() => () => clearTimeout(flashRef.current), [])

  useTicker(run !== null, (cache) => {
    const c = runRef.current
    if (!c) return

    const elapsed = performance.now() - c.startedAt
    const phase = (elapsed % c.beatIntervalMs) / c.beatIntervalMs

    if (approachRef.current) {
      approachRef.current.style.transform = `scale(${(2.2 - 1.2 * phase).toFixed(3)})`
    }

    const index = Math.floor(elapsed / c.beatIntervalMs)
    if (index !== cache.beatIndex) {
      cache.beatIndex = index
      const heart = heartRef.current
      if (heart) {
        heart.classList.remove('beat')
        void heart.offsetWidth
        heart.classList.add('beat')
      }
    }
  })

  if (!run) return null

  const done = beat.hits + beat.misses
  const accuracy = done > 0 ? beat.hits / done : 0

  return (
    <div className="rz-cpr">
      <div ref={stageRef} className="rz-cpr-stage">
        <svg className="rz-cpr-ring" viewBox="0 0 200 200">
          <circle className="rz-cpr-target" cx="100" cy="100" r="62" />
          <circle ref={approachRef} className="rz-cpr-approach" cx="100" cy="100" r="62" />
        </svg>

        <div className="rz-cpr-center">
          <span className="rz-cpr-key">SPACE</span>
          <span className={`rz-cpr-grade ${beat.grade}`.trim()}>{beat.grade}</span>
        </div>

        <div ref={heartRef} className="rz-cpr-heart" />
      </div>

      <div className="rz-cpr-info">
        <span className="rz-cpr-title">
          <i className="fa-solid fa-heart-pulse" />
          CPR — CHEST COMPRESSIONS
        </span>

        <div className="rz-cpr-meter">
          <span
            className={accuracy >= run.requiredAccuracy ? 'passing' : ''}
            style={{ width: `${Math.min(100, Math.round(accuracy * 100))}%` }}
          />
          <i style={{ left: `${Math.round(run.requiredAccuracy * 100)}%` }} />
        </div>

        <div className="rz-cpr-stats rz-num">
          <span>{beat.hits} / {run.totalBeats}</span>
          <span>{Math.round(accuracy * 100)}%</span>
          <span>{beat.streak >= 3 ? `x${beat.streak}` : ''}</span>
        </div>
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
