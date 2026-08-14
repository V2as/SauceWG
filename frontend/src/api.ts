export interface Client {
  id: number
  name: string
  address: string
  public_key: string
  status: 'active' | 'disabled' | 'limited' | 'expired'
  enabled: boolean
  data_limit: number
  reset_strategy: 'no_reset' | 'day' | 'week' | 'month'
  used_up: number
  used_down: number
  used_total: number
  lifetime_up: number
  lifetime_down: number
  expire_at: string | null
  last_handshake_at: string | null
  last_endpoint: string | null
  online_at: string | null
  is_online: boolean
  sub_token: string
  note: string | null
  created_at: string
  subscription_url: string
}

export interface CascadeStatus {
  enabled: boolean
  connected: boolean
  iface: string
  endpoint: string | null
  peer_public_key: string | null
  last_handshake_at: string | null
  rx_bytes: number
  tx_bytes: number
  exit_ip: string | null
  node: string | null
  mode: string
  nodes_total: number
  nodes_healthy: number
}

export interface ExitNode {
  name: string
  iface: string
  address: string
  priority: number
  endpoint: string | null
  exit_ip: string | null
  public_key: string
  peer_public_key: string | null
  paired: boolean
  healthy: boolean
  active: boolean
  last_handshake_at: string | null
  latency_ms: number | null
  rx_bytes: number
  tx_bytes: number
}

export interface ExitNodeList {
  mode: string
  active: string | null
  pinned: string | null
  killswitch: boolean
  stale: boolean
  updated_at: string | null
  nodes: ExitNode[]
}

export interface SystemStats {
  panel_title: string
  version: string
  cpu_percent: number
  cpu_cores: number
  mem_total: number
  mem_used: number
  disk_total: number
  disk_used: number
  uptime_seconds: number
  clients_total: number
  clients_active: number
  clients_online: number
  total_up: number
  total_down: number
  incoming_speed: number
  outgoing_speed: number
  node_ready: boolean
  server_public_key: string
  endpoint: string
  cascade: CascadeStatus
}

export interface UsageSeries {
  total_up: number
  total_down: number
  points: { bucket: string; up: number; down: number }[]
}

export interface Admin {
  id: number
  username: string
  is_sudo: boolean
  is_active: boolean
  created_at: string
  last_login_at: string | null
}

export interface NodeSettings {
  iface: string
  subnet: string
  address: string
  listen_port: number
  endpoint_host: string
  endpoint_port: number
  server_public_key: string
  mtu: number
  client_dns: string
  client_mtu: number
  client_allowed_ips: string
  obfuscation: Record<string, number>
}

const TOKEN_KEY = 'saucewg.token'

export const auth = {
  get token(): string | null {
    return localStorage.getItem(TOKEN_KEY)
  },
  set token(value: string | null) {
    if (value) localStorage.setItem(TOKEN_KEY, value)
    else localStorage.removeItem(TOKEN_KEY)
  },
}

export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  if (auth.token) headers.set('Authorization', `Bearer ${auth.token}`)
  if (init.body && !(init.body instanceof FormData) && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json')
  }

  const response = await fetch(`/api${path}`, { ...init, headers })
  if (response.status === 401) {
    auth.token = null
    window.dispatchEvent(new CustomEvent('saucewg:unauthorized'))
    throw new ApiError(401, 'Session expired')
  }
  if (!response.ok) {
    let detail = response.statusText
    try {
      const body = await response.json()
      detail = typeof body.detail === 'string' ? body.detail : JSON.stringify(body.detail)
    } catch {
      /* keep the status text */
    }
    throw new ApiError(response.status, detail)
  }
  if (response.status === 204) return undefined as T
  const type = response.headers.get('Content-Type') ?? ''
  if (type.includes('application/json')) return (await response.json()) as T
  return (await response.text()) as unknown as T
}

export const api = {
  async login(username: string, password: string) {
    const body = new URLSearchParams({ username, password })
    const response = await fetch('/api/admin/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    })
    if (!response.ok) {
      const detail = await response.json().catch(() => ({ detail: 'Login failed' }))
      throw new ApiError(response.status, detail.detail ?? 'Login failed')
    }
    const data = (await response.json()) as { access_token: string }
    auth.token = data.access_token
    return data
  },

  me: () => request<Admin>('/admin'),
  system: () => request<SystemStats>('/system'),
  nodeUsage: (hours: number) => request<UsageSeries>(`/system/usage?hours=${hours}`),
  settings: () => request<NodeSettings>('/settings'),
  forceSync: () => request<Record<string, number>>('/system/sync', { method: 'POST' }),

  exitNodes: () => request<ExitNodeList>('/nodes'),
  activateNode: (name: string) =>
    request<ExitNodeList>(`/nodes/${encodeURIComponent(name)}/activate`, { method: 'POST' }),
  autoFailover: () => request<ExitNodeList>('/nodes/auto', { method: 'POST' }),

  clients: (params: Record<string, string | number | undefined>) => {
    const query = new URLSearchParams()
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== '') query.set(key, String(value))
    }
    return request<{ total: number; items: Client[] }>(`/clients?${query}`)
  },
  createClient: (payload: Record<string, unknown>) =>
    request<Client>('/clients', { method: 'POST', body: JSON.stringify(payload) }),
  updateClient: (name: string, payload: Record<string, unknown>) =>
    request<Client>(`/clients/${encodeURIComponent(name)}`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    }),
  deleteClient: (name: string) =>
    request<void>(`/clients/${encodeURIComponent(name)}`, { method: 'DELETE' }),
  enableClient: (name: string) =>
    request<Client>(`/clients/${encodeURIComponent(name)}/enable`, { method: 'POST' }),
  disableClient: (name: string) =>
    request<Client>(`/clients/${encodeURIComponent(name)}/disable`, { method: 'POST' }),
  resetClient: (name: string) =>
    request<Client>(`/clients/${encodeURIComponent(name)}/reset`, { method: 'POST' }),
  clientConfig: (name: string) =>
    request<string>(`/clients/${encodeURIComponent(name)}/config`),
  clientUsage: (name: string, hours: number) =>
    request<UsageSeries>(`/clients/${encodeURIComponent(name)}/usage?hours=${hours}`),

  admins: () => request<Admin[]>('/admins'),
  createAdmin: (payload: Record<string, unknown>) =>
    request<Admin>('/admins', { method: 'POST', body: JSON.stringify(payload) }),
  updateAdmin: (username: string, payload: Record<string, unknown>) =>
    request<Admin>(`/admins/${encodeURIComponent(username)}`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    }),
  deleteAdmin: (username: string) =>
    request<void>(`/admins/${encodeURIComponent(username)}`, { method: 'DELETE' }),
}

// The subscription route is token-authenticated, so an <img> tag can load it without
// having to attach the admin bearer header.
export function qrUrl(client: Client): string {
  return `/sub/${client.sub_token}/qr`
}
