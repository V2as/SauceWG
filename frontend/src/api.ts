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
  // True when `node` is the exit node clients are routed through and it has stopped
  // handshaking without failover moving them off it. `connected` is false alongside.
  stalled: boolean
  mode: string
  nodes_total: number
  nodes_healthy: number
  // What happens while no exit node can carry traffic, and whether it is happening.
  fallback: 'direct' | 'block'
  fallback_active: boolean
  direct_routes: number
  // Destinations the entry node is reopening for itself. Zero and inactive is the
  // normal state of a healthy cascade: in `auto` the redirect only exists while
  // client traffic is leaving through this server.
  bypass_active: boolean
  bypass_routes: number
}

// What the panel's own recovery has been doing about a node that is down. Null while
// the node is healthy, or before the first attempt.
export interface NodeRecovery {
  attempts: number
  // 'probe' | 'restart' | 'repair': how far the last attempt escalated.
  last_action: string | null
  last_error: string | null
  // 'unreachable' when the server does not answer SSH at all, 'exhausted' when the
  // attempt budget is spent. Either way nothing further will be tried unattended.
  blocked: string | null
  down_for_seconds: number
  since_last_attempt_seconds: number | null
  recovered: boolean
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
  // True when the node container still calls this uplink usable but its last
  // handshake is too old for that to be true, so the panel reports it as down.
  // `active` can be true alongside it: client traffic is being pointed at an exit
  // node that is not answering, which is the state this exists to make visible.
  stalled: boolean
  last_handshake_at: string | null
  handshake_age_seconds: number | null
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
  recovery: NodeRecovery | null
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
  fallback: 'direct' | 'block'
  fallback_active: boolean
  stale: boolean
  updated_at: string | null
  config_error: string | null
  provisioning: boolean
  nodes: ExitNode[]
}

export interface DirectRoute {
  cidr: string
  note: string | null
  enabled: boolean
  // True once the node container has it in its routing table.
  active: boolean
}

export interface DirectRouteList {
  routes: DirectRoute[]
  via: string | null
  live: boolean
  editable: boolean
  config_error: string | null
}

// Destinations blocked at connection establishment rather than by route: the SYN to
// their IPv4 is dropped, so no route reaches them. The entry node opens the outbound
// half itself, over the destination's IPv6 or by retrying its IPv4.
export interface BypassEntry {
  cidr: string
  // The IPv6 address of the same server, tried first when known. Null means the
  // destination's own IPv4 is dialled until a handshake lands.
  v6: string | null
  note: string | null
  enabled: boolean
  // True while the node container is redirecting it. In `auto` every entry reads
  // false whenever an exit node is carrying client traffic.
  active: boolean
  // From a group the node image ships rather than from the list the panel edits, so
  // it can be turned off but not deleted.
  built_in: boolean
}

export interface BypassRelay {
  listen: string | null
  prefixes: number
  open: number
  accepted: number
  via_v6: number
  via_retry: number
  failed: number
  attempts: number
  cooled: number
  rx_bytes: number
  tx_bytes: number
  last_error: string | null
}

export interface BypassList {
  mode: 'auto' | 'always' | 'off'
  groups: string[]
  entries: BypassEntry[]
  active: boolean
  relay: BypassRelay | null
  live: boolean
  editable: boolean
  config_error: string | null
}

// One client the torrent guard has caught. The list is a reporting window rather
// than a penalty: nothing about a client is blocked for being on it.
export interface TorrentOffender {
  address: string
  name: string | null
  client_id: number | null
  packets: number
  expires_in: number
}

// Which of the kernel matches the filter is built on this host has. Without
// `string` there is no signature layer and the guard degrades to a port filter.
export interface TorrentCapabilities {
  string: boolean
  ipset: boolean
  connbytes: boolean
  comment: boolean
}

export interface TorrentStatus {
  enabled: boolean
  mode: 'on' | 'strict'
  // What the node container says it is doing, which lags the two above by up to a
  // second while a change is applied.
  active: boolean
  active_mode: string | null
  rules: number
  capabilities: TorrentCapabilities
  // Packets dropped per layer, plus `total`.
  blocked: Record<string, number>
  // Addresses caught speaking BitTorrent and dropped on sight since.
  peers: number
  clients: TorrentOffender[]
  live: boolean
  editable: boolean
  config_error: string | null
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
  // Restart the server's service and re-pair it if that is not enough. Takes no
  // credentials: it uses the panel's own key, which is what lets the same escalation
  // run unattended on a timer.
  recoverNode: (name: string) =>
    request<NodeTask>(`/nodes/${encodeURIComponent(name)}/recover`, { method: 'POST' }),
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

  // Destinations that bypass the cascade. The prefix is part of the path and
  // contains a slash, which the API takes as-is.
  routes: () => request<DirectRouteList>('/routes'),
  addRoutes: (payload: { cidr: string[]; note?: string | null }) =>
    request<DirectRouteList>('/routes', { method: 'POST', body: JSON.stringify(payload) }),
  updateRoute: (cidr: string, payload: { note?: string | null; enabled?: boolean }) =>
    request<DirectRouteList>(`/routes/${cidr}`, { method: 'PUT', body: JSON.stringify(payload) }),
  deleteRoute: (cidr: string) => request<DirectRouteList>(`/routes/${cidr}`, { method: 'DELETE' }),

  // Destinations the entry node reopens for itself. The mode is not settable from
  // here: it lives in the node container's environment, so it is `saucewg bypass`.
  bypass: () => request<BypassList>('/bypass'),
  addBypass: (payload: { cidr: string[]; v6?: string | null; note?: string | null }) =>
    request<BypassList>('/bypass', { method: 'POST', body: JSON.stringify(payload) }),
  updateBypass: (
    cidr: string,
    payload: { v6?: string | null; note?: string | null; enabled?: boolean },
  ) => request<BypassList>(`/bypass/${cidr}`, { method: 'PUT', body: JSON.stringify(payload) }),
  deleteBypass: (cidr: string) => request<BypassList>(`/bypass/${cidr}`, { method: 'DELETE' }),

  // BitTorrent in the traffic this node forwards. One switch and one dial, both
  // optional, so the mode survives being turned off and on again.
  torrents: () => request<TorrentStatus>('/torrents'),
  setTorrents: (payload: { enabled?: boolean; mode?: 'on' | 'strict' }) =>
    request<TorrentStatus>('/torrents', { method: 'PUT', body: JSON.stringify(payload) }),

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
