import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

import '@pr/ui/vendor'
import '@pr/ui/style.css'
import './styles/redzone.css'

import App from './app'

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
