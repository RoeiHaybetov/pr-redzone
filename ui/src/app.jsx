import { Component } from 'react'
import { CrateHud, KnockHud, CprHud, InviteToast } from './hud'
import SquadPanel from './squad'
import AdminPanel from './admin/Panel'

class Boundary extends Component {
  constructor(props) {
    super(props)
    this.state = { failed: false }
  }

  static getDerivedStateFromError() {
    return { failed: true }
  }

  componentDidCatch(error, info) {
    console.error(`[pr-redzone] ${this.props.name} failed to render`, error, info)
  }

  render() {
    return this.state.failed ? null : this.props.children
  }
}

const SURFACES = [
  ['crate', CrateHud],
  ['knock', KnockHud],
  ['cpr', CprHud],
  ['invite toast', InviteToast],
  ['squad panel', SquadPanel],
  ['admin panel', AdminPanel],
]

export default function App() {
  return (
    <>
      {SURFACES.map(([name, Surface]) => (
        <Boundary key={name} name={name}>
          <Surface />
        </Boundary>
      ))}
    </>
  )
}
