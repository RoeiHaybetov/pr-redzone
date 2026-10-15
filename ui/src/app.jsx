import { Component } from 'react'
import { CrateHud, InviteToast } from './hud'
import SquadPanel from './squad'
import AdminPanel from './admin/Panel'
import { post } from './lib'

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
    if (!this.props.release) return
    post(this.props.release, {})
    this.setState({ failed: false })
  }

  render() {
    return this.state.failed ? null : this.props.children
  }
}

const SURFACES = [
  ['crate', CrateHud],
  ['invite toast', InviteToast],
  ['squad panel', SquadPanel, 'close'],
  ['admin panel', AdminPanel, 'rzAdminClose'],
]

export default function App() {
  return (
    <>
      {SURFACES.map(([name, Surface, release]) => (
        <Boundary key={name} name={name} release={release}>
          <Surface />
        </Boundary>
      ))}
    </>
  )
}
