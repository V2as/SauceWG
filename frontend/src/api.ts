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
  // Which AmneziaWG generation this uplink speaks. Null from a node container that
  // predates generation selection, which is serving 1.0 either way.
  protocol: string | null
  managed: boolean
  ssh_host: string | null
  ssh_port: number | null
  ssh_user: string | null
  // True when the panel's own key is on that server, so managing it needs no password.
  ssh_key: boolean
  created_at: string | null
  task_id: string | null
}

export interface PanelSshKey {
  public_key: string
  fingerprint: string
  created_at: string | null
  enabled: boolean
}

export interface NodeCheckResult {
  reachable: boolean
  error: string | null
  root: boolean
  os: string | null
  kernel: string | null
  arch: string | null
  cpus: number
  memory_mb: number
  disk_free_mb: number
  uptime_seconds: number
  docker: boolean
  saucewg: boolean
  role: string | null
  host_key: string | null
  used_panel_key: boolean
}

export interface NodeStatus {
  name: string
  reachable: boolean
  error: string | null
  ssh_host: string | null
  role: string | null
  cli_version: string | null
  dir: string | null
  os: string | null
  kernel: string | null
  arch: string | null
  cpus: number
  memory_mb: number
  disk_free_mb: number
  uptime_seconds: number
  docker: boolean
  saucewg: boolean
  containers: { name: string; state: string; status: string }[]
}

export interface NodeLogs {
  name: string
  service: string | null
  lines: number
  text: string
}

export interface ExitNodeList {
  mode: string
  active: string | null
  pinned: string | null
  killswitch: boolean
  stale: boolean
  updated_at: string | null
  config_error: string | null
  provisioning: boolean
  nodes: ExitNode[]
}

export type TaskStatus = 'pending' | 'running' | 'succeeded' | 'failed'

export interface NodeTask {
  id: string
  action: string
  target: string
  status: TaskStatus
  step: string
  error: string | null
  result: Record<string, unknown> | null
  created_at: string
  finished_at: string | null
  log: { at: string; text: string }[]
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
  protocol: string
  protocols_supported: string[]
  // Only the parameters the generation in force carries. Values are strings because
  // an H-parameter may be a range and I1-I5 are signature specs.
  obfuscation: Record<string, string>
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

  // Installing a node takes minutes, so these return a task to poll rather than
  // holding the request open.
  createNode: (payload: Record<string, unknown>) =>
    request<NodeTask>('/nodes', { method: 'POST', body: JSON.stringify(payload) }),
  adoptNode: (payload: Record<string, unknown>) =>
    request<ExitNodeList>('/nodes/adopt', { method: 'POST', body: JSON.stringify(payload) }),
  updateNode: (name: string, payload: Record<string, unknown>) =>
    request<ExitNodeList>(`/nodes/${encodeURIComponent(name)}`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    }),
  deleteNode: (name: string, payload: Record<string, unknown>) =>
    request<NodeTask>(`/nodes/${encodeURIComponent(name)}`, {
      method: 'DELETE',
      body: JSON.stringify(payload),
    }),
  repairNode: (name: string, payload: Record<string, unknown>) =>
    request<NodeTask>(`/nodes/${encodeURIComponent(name)}/repair`, {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  // Both ends have to move together, so this reconfigures the exit node over SSH and
  // rebuilds the uplink with the profile it reports back.
  setNodeProtocol: (name: string, payload: Record<string, unknown>) =>
    request<NodeTask>(`/nodes/${encodeURIComponent(name)}/protocol`, {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  nodeTask: (id: string) => request<NodeTask>(`/nodes/tasks/${encodeURIComponent(id)}`),

  // The panel's own SSH key. Adding it to a server before installing means the
  // install, and everything after it, needs no root password.
  panelSshKey: () => request<PanelSshKey>('/nodes/ssh-key'),
  checkServer: (payload: Record<string, unknown>) =>
    request<NodeCheckResult>('/nodes/check', { method: 'POST', body: JSON.stringify(payload) }),

  nodeStatus: (name: string) => request<NodeStatus>(`/nodes/${encodeURIComponent(name)}/status`),
  nodeLogs: (name: string, service?: string, lines = 200) => {
    const query = new URLSearchParams({ lines: String(lines) })
    if (service) query.set('service', service)
    return request<NodeLogs>(`/nodes/${encodeURIComponent(name)}/logs?${query}`)
  },
  // Credentials are optional on a node that carries the panel's key, which is why
  // these send a body at all rather than nothing.
  nodeService: (name: string, action: 'start' | 'stop' | 'restart', payload: Record<string, unknown> = {}) =>
    request<NodeTask>(`/nodes/${encodeURIComponent(name)}/${action}`, {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  upgradeNode: (name: string, payload: Record<string, unknown> = {}) =>
    request<NodeTask>(`/nodes/${encodeURIComponent(name)}/upgrade`, {
      method: 'POST',
      body: JSON.stringify(payload),
    }),

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
