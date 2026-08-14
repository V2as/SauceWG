import { reactive, readonly } from 'vue'
import type { Admin } from './api'

interface Toast {
  id: number
  message: string
  kind: 'info' | 'success' | 'error'
}

const state = reactive({
  admin: null as Admin | null,
  toasts: [] as Toast[],
})

let nextId = 1

export function notify(message: string, kind: Toast['kind'] = 'info', ttl = 3800) {
  const toast: Toast = { id: nextId++, message, kind }
  state.toasts.push(toast)
  setTimeout(() => {
    const index = state.toasts.findIndex((t) => t.id === toast.id)
    if (index !== -1) state.toasts.splice(index, 1)
  }, ttl)
}

export function setAdmin(admin: Admin | null) {
  state.admin = admin
}

export const store = readonly(state)
