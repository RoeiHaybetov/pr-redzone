import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react'
import { resourceName, setResourceFallback } from '@pr/ui'

setResourceFallback('pr-redzone')

export { isBrowser, resourceName } from '@pr/ui'

export async function post(endpoint, payload) {
  try {
    const res = await fetch(`https://${resourceName()}/${endpoint}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(payload || {}),
    })
    return await res.json()
  } catch {
    return { ok: false, error: 'error.generic' }
  }
}

let bundle = {}
const listeners = new Set()

export function setLocales(next) {
  if (!next || typeof next !== 'object' || next === bundle) return
  bundle = next
  listeners.forEach((fn) => fn())
}

function subscribe(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

function snapshot() {
  return bundle
}

export function useT() {
  const active = useSyncExternalStore(subscribe, snapshot, snapshot)

  return useCallback((key, fallback) => {
    const value = active[key]
    if (typeof value === 'string' && value !== key) return value
    return fallback !== undefined ? fallback : key
  }, [active])
}

export function useAsync(endpoint, payload) {
  const [data, setData] = useState(undefined)
  const key = payload === undefined ? '' : JSON.stringify(payload)
  const token = useRef(0)

  const reload = useCallback(async () => {
    const id = ++token.current
    const res = await post(endpoint, key ? JSON.parse(key) : undefined)
    if (id !== token.current) return
    setData(res && res.ok ? res : null)
  }, [endpoint, key])

  useEffect(() => {
    setData(undefined)
    reload()
    return () => { token.current += 1 }
  }, [reload])

  return { data, reload }
}

export function useConfirm() {
  const [dialog, setDialog] = useState(null)
  const [shownDialog, setShownDialog] = useState(null)
  const [value, setValue] = useState('')
  const [error, setError] = useState('')

  useEffect(() => { if (dialog) setShownDialog(dialog) }, [dialog])

  const ask = useCallback((opts) => {
    setValue(opts.value !== undefined ? opts.value : (opts.textarea !== undefined ? opts.textarea : ''))
    setError('')
    setDialog(opts)
  }, [])

  const close = useCallback(() => {
    setDialog(null)
    setError('')
  }, [])

  return { dialog, shownDialog, ask, close, value, setValue, error, setError }
}
