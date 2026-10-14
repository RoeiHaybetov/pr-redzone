import { EmptyState } from '@pr/ui'
import { useAdmin } from '../core'
import { Groups } from '../fields'

export default function Settings({ section }) {
  const { cfg, active, search } = useAdmin()
  const sectionId = section === undefined ? active : section
  const term = (search || '').trim().toLowerCase()

  const fields = term
    ? cfg.fields.filter((f) => (f.label && f.label.toLowerCase().includes(term))
      || (f.path && f.path.toLowerCase().includes(term))
      || (f.desc && f.desc.toLowerCase().includes(term)))
    : cfg.fields.filter((f) => f.section === sectionId)

  if (!fields.length) {
    return (
      <EmptyState
        icon="fa-magnifying-glass"
        title={term ? `Nothing matches “${search}”.` : 'No settings in this section.'}
      />
    )
  }

  return <Groups fields={fields} expanded={!!term} />
}
