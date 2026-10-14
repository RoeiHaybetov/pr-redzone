import { createContext, useContext } from 'react'
import { Button, Dialog, Input } from '@pr/ui'

export const AdminContext = createContext(null)

export function useAdmin() {
  return useContext(AdminContext)
}

export function same(a, b) {
  if (a === b) return true
  if (typeof a !== typeof b) return false
  if (a === null || b === null) return false
  if (typeof a !== 'object') return false

  const ka = Object.keys(a)
  const kb = Object.keys(b)
  if (ka.length !== kb.length) return false
  return ka.every((k) => same(a[k], b[k]))
}

export function clone(v) {
  return v === undefined ? undefined : JSON.parse(JSON.stringify(v))
}

export function ApplyChip({ mode }) {
  if (!mode) return null
  const label = mode === 'live' ? 'live' : mode === 'session' ? 'next session' : 'restart'
  return <span className={`rz-chip ${mode}`}>{label}</span>
}

export function DiffItem({ item }) {
  return (
    <div className="rz-diff-item">
      <div className="rz-diff-label">
        <span>{item.label || item.path}</span>
        <ApplyChip mode={item.apply} />
      </div>
      <div className="rz-diff-values rz-num">
        <span className="rz-diff-before">{String(item.before)}</span>
        <span className="rz-diff-arrow">→</span>
        <span className="rz-diff-after">{String(item.after)}</span>
      </div>
    </div>
  )
}

export function StatLine({ label, value }) {
  return (
    <div className="rz-stat-line">
      <span>{label}</span>
      <span>{String(value)}</span>
    </div>
  )
}

export function DialogHost({ confirm, cancelLabel = 'Cancel', confirmLabel = 'Confirm' }) {
  const { dialog, shownDialog, close, value, setValue, error, setError } = confirm
  const d = shownDialog

  const buttons = d
    ? (d.buttons || [{ label: d.confirmLabel || confirmLabel, danger: d.danger, fn: d.onConfirm }])
    : []

  const run = async (btn) => {
    const res = btn.fn ? await btn.fn(value) : null
    if (res && res.error) { setError(res.error); return }
    close()
  }

  const hasContent = !!d && !!(
    d.input
    || d.textarea !== undefined
    || (d.list && d.list.length)
    || (d.diff && d.diff.length)
    || error
  )

  return (
    <Dialog
      open={!!dialog}
      onCancel={close}
      className={[
        d && d.wide ? 'rz-dialog-wide' : '',
        `rz-dialog-actions-${buttons.length + 1}`,
      ].filter(Boolean).join(' ')}
      tone={d && d.danger ? 'danger' : 'default'}
      icon={d && d.danger ? 'fa-triangle-exclamation' : 'fa-circle-question'}
      title={d && d.title}
      body={d && d.body}
      content={hasContent ? (
        <>
          {d.input ? (
            <Input
              autoFocus
              value={value}
              maxLength={d.maxLength}
              placeholder={d.placeholder || ''}
              onChange={(e) => setValue(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter' && buttons.length) run(buttons[buttons.length - 1])
              }}
            />
          ) : null}

          {d.textarea !== undefined ? (
            <textarea
              className="rz-textarea rz-scrollable"
              readOnly={!d.editable}
              spellCheck="false"
              value={value}
              onChange={(e) => setValue(e.target.value)}
            />
          ) : null}

          {d.list && d.list.length ? (
            <div className="rz-warn-list">
              {d.list.map((entry, i) => (
                <div key={i} className={`rz-warn-item ${entry.kind === 'error' ? 'is-error' : ''}`.trim()}>
                  {entry.text}
                </div>
              ))}
            </div>
          ) : null}

          {d.diff && d.diff.length ? (
            <div className="rz-diff">
              {d.diff.map((item, i) => <DiffItem key={i} item={item} />)}
            </div>
          ) : null}

          {error ? <div className="rz-field-err">{error}</div> : null}
        </>
      ) : null}
    >
      <Button variant="ghost" onClick={close}>{cancelLabel}</Button>
      {buttons.map((b, i) => (
        <Button
          key={i}
          variant={b.danger ? 'danger' : 'primary'}
          onClick={() => run(b)}
        >
          {b.label}
        </Button>
      ))}
    </Dialog>
  )
}
