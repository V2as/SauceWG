<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import {
  api,
  type ExitNode,
  type ExitNodeList,
  type NodeCheckResult,
  type NodeStatus,
  type NodeTask,
  type PanelSshKey,
} from '../api'
import ModalShell from '../components/ModalShell.vue'
import { notify } from '../store'
import { bytes, dateTime, duration, relativeTime } from '../utils/format'

const state = ref<ExitNodeList | null>(null)
const panelKey = ref<PanelSshKey | null>(null)
const busy = ref('')
const error = ref('')
let timer: number | undefined
let taskTimer: number | undefined

const adding = ref(false)
const removing = ref<ExitNode | null>(null)
const repairing = ref<ExitNode | null>(null)
const recovering = ref<ExitNode | null>(null)
const editing = ref<ExitNode | null>(null)
const switching = ref<ExitNode | null>(null)
const managing = ref<ExitNode | null>(null)
const task = ref<NodeTask | null>(null)

const probe = ref<NodeCheckResult | null>(null)
const remote = ref<NodeStatus | null>(null)
const logs = ref('')

const healthy = computed(() => state.value?.nodes.filter((n) => n.healthy).length ?? 0)
const taskRunning = computed(() => task.value !== null && !['succeeded', 'failed'].includes(task.value.status))

// The generations an exit node can serve, newest first. 2.0 is the default for a new
// install; 1.0 is what an older Keenetic on the client side needs.
const PROTOCOLS = ['2.0', '1.5', '1.0']
const SIGNATURES = ['quic', 'dns', 'random', 'short', 'none']

const blank = {
  name: '',
  host: '',
  ssh_port: 22,
  ssh_user: 'root',
  ssh_password: '',
  port: 51820,
  priority: null as number | null,
  preshared_key: '',
  protocol: '2.0',
  signature: 'quic',
  note: '',
}
const form = ref({ ...blank })
const removeForm = ref({ uninstall: false, ssh_password: '' })
const repairForm = ref({ ssh_password: '' })
const editForm = ref({ priority: 0, note: '' })
const protocolForm = ref({ protocol: '2.0', signature: 'quic', ssh_password: '' })

async function refresh() {
  try {
    state.value = await api.exitNodes()
    error.value = ''
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  }
}

/** Reading the key is what creates it, so this also seeds a fresh installation. */
async function loadPanelKey() {
  try {
    panelKey.value = await api.panelSshKey()
  } catch {
    // A panel that cannot keep a key still manages nodes, it just asks for a
    // password every time — so this is not worth an error banner.
    panelKey.value = null
  }
}

async function activate(node: ExitNode) {
  busy.value = node.name
  try {
    state.value = await api.activateNode(node.name)
    notify(`Cascade pinned to ${node.name}`, 'success')
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function auto() {
  busy.value = 'auto'
  try {
    state.value = await api.autoFailover()
    notify('Automatic failover restored', 'success')
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

/** Follows a provisioning task until it finishes, streaming its log into the modal. */
function follow(started: NodeTask, onDone: (final: NodeTask) => void) {
  task.value = started
  window.clearInterval(taskTimer)
  taskTimer = window.setInterval(async () => {
    try {
      const current = await api.nodeTask(started.id)
      task.value = current
      if (current.status === 'succeeded' || current.status === 'failed') {
        window.clearInterval(taskTimer)
        await refresh()
        onDone(current)
      }
    } catch (err) {
      window.clearInterval(taskTimer)
      notify(err instanceof Error ? err.message : String(err), 'error')
    }
  }, 1200)
}

function openAdd() {
  form.value = { ...blank }
  task.value = null
  probe.value = null
  adding.value = true
}

/** A dry run against the server, so a wrong password fails in a second rather than
 *  several minutes into an install. */
async function checkServer() {
  busy.value = 'check'
  probe.value = null
  try {
    probe.value = await api.checkServer({
      host: form.value.host.trim(),
      ssh_port: form.value.ssh_port,
      ssh_user: form.value.ssh_user.trim() || 'root',
      ssh_password: form.value.ssh_password || null,
    })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function submitAdd() {
  busy.value = 'add'
  try {
    const started = await api.createNode({
      name: form.value.name.trim(),
      host: form.value.host.trim(),
      ssh_port: form.value.ssh_port,
      ssh_user: form.value.ssh_user.trim() || 'root',
      // Blank is meaningful: the panel then logs in with its own key.
      ssh_password: form.value.ssh_password || null,
      port: form.value.port,
      priority: form.value.priority,
      preshared_key: form.value.preshared_key || null,
      protocol: form.value.protocol,
      // I1 exists on 1.5 and 2.0 only; sending it for 1.0 would be ignored anyway,
      // but leaving it out keeps the request honest about what was asked for.
      signature: form.value.protocol === '1.0' ? null : form.value.signature,
      note: form.value.note || null,
    })
    // The password only ever existed in this form; drop it as soon as it is sent.
    form.value.ssh_password = ''
    follow(started, (final) => {
      if (final.status === 'succeeded') {
        notify(`${final.target} joined the cascade`, 'success')
      } else {
        notify(final.error ?? `Installing ${final.target} failed`, 'error')
      }
    })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

function openRemove(node: ExitNode) {
  removeForm.value = { uninstall: false, ssh_password: '' }
  task.value = null
  removing.value = node
}

async function submitRemove() {
  if (!removing.value) return
  const name = removing.value.name
  busy.value = name
  try {
    const started = await api.deleteNode(name, {
      uninstall: removeForm.value.uninstall,
      ssh_password: removeForm.value.ssh_password || null,
    })
    removeForm.value.ssh_password = ''
    follow(started, (final) => {
      if (final.status === 'succeeded') notify(`${name} removed`, 'success')
      else notify(final.error ?? `Removing ${name} failed`, 'error')
    })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

function openRepair(node: ExitNode) {
  repairForm.value = { ssh_password: '' }
  task.value = null
  repairing.value = node
}

async function submitRepair() {
  if (!repairing.value) return
  const name = repairing.value.name
  busy.value = name
  try {
    const started = await api.repairNode(name, { ssh_password: repairForm.value.ssh_password })
    repairForm.value.ssh_password = ''
    follow(started, (final) => {
      if (final.status === 'succeeded') notify(`${name} re-paired`, 'success')
      else notify(final.error ?? `Re-pairing ${name} failed`, 'error')
    })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

function openEdit(node: ExitNode) {
  editForm.value = { priority: node.priority, note: '' }
  editing.value = node
}

async function submitEdit() {
  if (!editing.value) return
  const name = editing.value.name
  try {
    state.value = await api.updateNode(name, {
      priority: editForm.value.priority,
      note: editForm.value.note || null,
    })
    notify(`${name} updated`, 'success')
    editing.value = null
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

function openProtocol(node: ExitNode) {
  protocolForm.value = {
    protocol: node.protocol ?? '1.0',
    signature: 'quic',
    ssh_password: '',
  }
  task.value = null
  switching.value = node
}

async function submitProtocol() {
  if (!switching.value) return
  const name = switching.value.name
  const target = protocolForm.value.protocol
  busy.value = name
  try {
    const started = await api.setNodeProtocol(name, {
      protocol: target,
      signature: target === '1.0' ? null : protocolForm.value.signature,
      ssh_password: protocolForm.value.ssh_password,
    })
    protocolForm.value.ssh_password = ''
    follow(started, (final) => {
      if (final.status === 'succeeded') notify(`${name} now serves AmneziaWG ${target}`, 'success')
      else notify(final.error ?? `Moving ${name} to ${target} failed`, 'error')
    })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

function openManage(node: ExitNode) {
  managing.value = node
  remote.value = null
  logs.value = ''
  task.value = null
  loadStatus()
}

async function loadStatus() {
  if (!managing.value) return
  busy.value = 'status'
  try {
    remote.value = await api.nodeStatus(managing.value.name)
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function loadLogs(service: string) {
  if (!managing.value) return
  busy.value = 'logs'
  try {
    logs.value = (await api.nodeLogs(managing.value.name, service, 200)).text || '(no output)'
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function service(action: 'start' | 'stop' | 'restart') {
  if (!managing.value) return
  const name = managing.value.name
  busy.value = name
  try {
    const started = await api.nodeService(name, action)
    follow(started, (final) => {
      if (final.status === 'succeeded') notify(`${name} ${action}ed`, 'success')
      else notify(final.error ?? `${action} failed on ${name}`, 'error')
      loadStatus()
    })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

/** Puts a failed node back: restart the server's service, then re-pair if that was
 *  not enough. The panel does the same on a timer; this is it now, without waiting
 *  out the grace period or the backoff. */
async function recover(node: ExitNode) {
  const name = node.name
  busy.value = name
  try {
    const started = await api.recoverNode(name)
    task.value = null
    recovering.value = node
    follow(started, (final) => {
      const outcome = final.result as { healthy?: boolean } | null
      if (outcome?.healthy) notify(`${name} is carrying traffic again`, 'success')
      else if (final.status === 'failed') notify(final.error ?? `Recovering ${name} failed`, 'error')
      else notify(`${name} did not come back; see the log`, 'error')
    })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function upgrade() {
  if (!managing.value) return
  const name = managing.value.name
  busy.value = name
  try {
    const started = await api.upgradeNode(name)
    follow(started, (final) => {
      if (final.status === 'succeeded') notify(`${name} upgraded`, 'success')
      else notify(final.error ?? `Upgrading ${name} failed`, 'error')
      loadStatus()
    })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

function closeTaskModal() {
  if (taskRunning.value) return
  window.clearInterval(taskTimer)
  adding.value = false
  removing.value = null
  repairing.value = null
  recovering.value = null
  switching.value = null
  managing.value = null
  task.value = null
}

function copy(text: string, label: string) {
  navigator.clipboard.writeText(text).then(
    () => notify(`${label} copied`, 'success'),
    () => notify('Clipboard is unavailable', 'error'),
  )
}

function statusLabel(node: ExitNode) {
  if (node.task_id) return { text: 'working', klass: 'badge-limited' }
  if (!node.paired) return { text: 'unpaired', klass: 'badge-limited' }
  if (node.active) return { text: 'active', klass: 'badge-active' }
  if (node.healthy) return { text: 'standby', klass: 'badge-disabled' }
  return { text: 'down', klass: 'badge-expired' }
}

/** One line under a failed node's status, saying what is being done about it. */
function recoveryLabel(node: ExitNode) {
  const r = node.recovery
  if (!r || node.healthy) return ''
  const down = `down ${duration(r.down_for_seconds)}`
  if (r.blocked === 'unreachable') return `${down} · the server does not answer`
  if (r.blocked === 'exhausted') return `${down} · recovery gave up after ${r.attempts} tries`
  if (!r.attempts) return `${down} · waiting before touching it`
  const tried = { probe: 'probed', restart: 'restarted', repair: 're-paired' }[r.last_action ?? ''] ?? 'tried'
  return `${down} · ${tried}, attempt ${r.attempts}`
}

/** True while nothing further will happen on its own, so the operator is the next
 *  step — either here or on the server itself. */
function needsAttention(node: ExitNode) {
  return !node.healthy && (node.recovery?.blocked ?? null) !== null
}

const stranded = computed(() => state.value?.nodes.filter(needsAttention) ?? [])

onMounted(() => {
  refresh()
  loadPanelKey()
  timer = window.setInterval(refresh, 5000)
})
onUnmounted(() => {
  window.clearInterval(timer)
  window.clearInterval(taskTimer)
})
</script>

<template>
  <div class="page-head">
    <div>
      <h1>Exit nodes</h1>
      <p>Every configured exit node stays connected; only one carries client traffic</p>
    </div>
    <div class="row">
      <button class="btn" :disabled="busy !== '' || state?.mode === 'auto'" @click="auto">
        {{ state?.mode === 'auto' ? 'Automatic failover on' : 'Return to automatic' }}
      </button>
      <button class="btn btn-primary" :disabled="!state?.provisioning" @click="openAdd">
        + Add exit node
      </button>
    </div>
  </div>

  <div v-if="error" class="alert alert-error" style="margin-bottom: 14px">{{ error }}</div>

  <template v-if="state">
    <div v-if="state.config_error" class="alert alert-error" style="margin-bottom: 14px">
      {{ state.config_error }}
    </div>

    <div v-if="state.stale" class="alert alert-warn" style="margin-bottom: 14px">
      The node container has not refreshed its uplink state since
      {{ dateTime(state.updated_at) }}. The health data below is stale and failover is
      probably not running.
    </div>

    <div v-else-if="state.fallback_active" class="alert alert-warn" style="margin-bottom: 14px">
      <template v-if="state.fallback === 'direct'">
        No exit node can carry traffic, so clients are leaving through this entry node
        and their traffic appears from its address. They are moved back onto the cascade
        as soon as an exit node recovers.
      </template>
      <template v-else>
        No exit node can carry traffic and the fallback is set to block, so clients are
        cut off until one recovers.
      </template>
    </div>

    <div v-if="stranded.length" class="alert alert-warn" style="margin-bottom: 14px">
      Automatic recovery has stopped trying
      <span class="mono">{{ stranded.map((n) => n.name).join(', ') }}</span
      >.
      <template v-if="stranded.some((n) => n.recovery?.blocked === 'unreachable')">
        A server that does not answer SSH at all cannot be repaired from here — check
        whether the VPS still exists at its provider.
      </template>
      <template v-else>
        Restarting and re-pairing both ran without the tunnel coming back, so the exit
        server needs looking at directly.
      </template>
    </div>

    <div v-if="!state.provisioning && !state.config_error" class="alert alert-warn" style="margin-bottom: 14px">
      Exit node management is turned off, so the list below is read-only. Set
      <span class="mono">NODE_PROVISION_ENABLED=true</span> to add and remove nodes from here.
    </div>

    <div v-if="!state.nodes.length" class="empty">
      <template v-if="state.provisioning">
        No exit node is configured yet. Add one — you will need its IP address and the
        root password; everything else is installed for you.
      </template>
      <template v-else>
        No exit node is configured yet, and this panel cannot add one.
      </template>
    </div>

    <template v-else>
      <div class="grid grid-4" style="margin-bottom: 14px">
        <div class="card">
          <div class="stat-label">Active exit</div>
          <div class="stat-value">{{ state.active ?? '—' }}</div>
          <div class="stat-sub">
            {{ state.mode === 'manual' ? `pinned to ${state.pinned}` : 'chosen automatically' }}
          </div>
        </div>

        <div class="card">
          <div class="stat-label">Healthy nodes</div>
          <div class="stat-value">{{ healthy }} / {{ state.nodes.length }}</div>
          <div class="stat-sub">failover targets available</div>
        </div>

        <div class="card">
          <div class="stat-label">If every node fails</div>
          <div class="stat-value row" style="gap: 9px">
            <i class="dot" :class="{ on: !state.fallback_active }"></i>
            <span>{{ state.fallback === 'direct' ? 'Via entry node' : 'Blocked' }}</span>
          </div>
          <div class="stat-sub">
            {{
              state.fallback_active
                ? (state.fallback === 'direct'
                    ? 'in use now: clients are on this server\'s address'
                    : 'in use now: client traffic is being dropped')
                : (state.fallback === 'direct'
                    ? 'clients stay online through this server'
                    : 'clients drop rather than leave via the entry IP')
            }}
          </div>
        </div>

        <div class="card">
          <div class="stat-label">Last health check</div>
          <div class="stat-value" style="font-size: 20px">{{ relativeTime(state.updated_at) }}</div>
          <div class="stat-sub">{{ dateTime(state.updated_at) }}</div>
        </div>
      </div>

      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th class="plain">Node</th>
              <th class="plain">Status</th>
              <th class="plain">Protocol</th>
              <th class="plain">Priority</th>
              <th class="plain">Exit endpoint</th>
              <th class="plain">Interface</th>
              <th class="plain">Latency</th>
              <th class="plain">Handshake</th>
              <th class="plain">Traffic</th>
              <th class="plain"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="node in state.nodes" :key="node.name">
              <td>
                <div class="row" style="gap: 9px">
                  <i class="dot" :class="{ on: node.active }"></i>
                  <strong>{{ node.name }}</strong>
                </div>
                <div class="mono" style="color: var(--text-dim)">
                  {{ node.address }}<template v-if="node.managed"> · managed</template><template
                    v-if="node.ssh_key"
                  > · keyed</template>
                </div>
              </td>
              <td>
                <span class="badge" :class="statusLabel(node).klass">{{ statusLabel(node).text }}</span>
                <div v-if="recoveryLabel(node)" class="stat-sub" style="margin-top: 4px"
                     :title="node.recovery?.last_error ?? ''">
                  {{ recoveryLabel(node) }}
                </div>
              </td>
              <td class="mono">{{ node.protocol ?? '1.0' }}</td>
              <td class="mono">{{ node.priority }}</td>
              <td class="mono">{{ node.endpoint ?? '—' }}</td>
              <td class="mono">{{ node.iface }}</td>
              <td class="mono">{{ node.latency_ms != null ? `${node.latency_ms.toFixed(1)} ms` : '—' }}</td>
              <td :title="dateTime(node.last_handshake_at)">{{ relativeTime(node.last_handshake_at) }}</td>
              <td>↑ {{ bytes(node.rx_bytes) }} · ↓ {{ bytes(node.tx_bytes) }}</td>
              <td>
                <div class="row" style="gap: 4px; justify-content: flex-end">
                  <button
                    class="btn btn-sm"
                    :disabled="busy !== '' || node.active || !node.paired || !!node.task_id"
                    @click="activate(node)"
                  >
                    Switch here
                  </button>
                  <button
                    class="btn btn-ghost btn-sm"
                    title="Priority and note"
                    :disabled="!state.provisioning || !!node.task_id"
                    @click="openEdit(node)"
                  >
                    ✎
                  </button>
                  <button
                    v-if="node.managed && !node.healthy"
                    class="btn btn-sm"
                    title="Restart this server's service, and re-pair it if that is not enough"
                    :disabled="busy !== '' || !state.provisioning || !!node.task_id || !node.ssh_key"
                    @click="recover(node)"
                  >
                    Recover
                  </button>
                  <button
                    v-if="node.managed"
                    class="btn btn-ghost btn-sm"
                    title="Status, logs, restart and upgrade"
                    :disabled="!!node.task_id"
                    @click="openManage(node)"
                  >
                    ⚙
                  </button>
                  <button
                    v-if="node.managed"
                    class="btn btn-ghost btn-sm"
                    title="Change the AmneziaWG generation this node serves"
                    :disabled="!state.provisioning || !!node.task_id"
                    @click="openProtocol(node)"
                  >
                    ⇅
                  </button>
                  <button
                    v-if="node.managed"
                    class="btn btn-ghost btn-sm"
                    title="Re-install the uplink key on this server"
                    :disabled="!state.provisioning || !!node.task_id"
                    @click="openRepair(node)"
                  >
                    ↻
                  </button>
                  <button
                    class="btn btn-ghost btn-sm"
                    title="Remove"
                    style="color: var(--danger)"
                    :disabled="!state.provisioning || !!node.task_id"
                    @click="openRemove(node)"
                  >
                    ✕
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div v-if="panelKey?.enabled" class="card" style="margin-top: 14px">
        <div class="stat-label" style="margin-bottom: 14px">This panel's SSH key</div>
        <p style="color: var(--text-dim); font-size: 12.5px; margin-top: 0">
          Installed on every node added from here, which is why managing one afterwards
          asks for no password. Add it to a new server at creation time — most providers
          have a field for it — and that server can be installed without a password too.
        </p>
        <dl class="kv" style="grid-template-columns: 140px 1fr">
          <dt>Public key</dt>
          <dd class="mono" style="cursor: pointer; word-break: break-all" title="Click to copy"
              @click="copy(panelKey.public_key, 'Panel SSH key')">
            {{ panelKey.public_key }}
          </dd>
          <dt>Fingerprint</dt>
          <dd class="mono">{{ panelKey.fingerprint }}</dd>
        </dl>
      </div>

      <div class="card" style="margin-top: 14px">
        <div class="stat-label" style="margin-bottom: 14px">Pairing keys</div>
        <p style="color: var(--text-dim); font-size: 12.5px; margin-top: 0">
          Each uplink has its own key pair. Nodes added from here are paired automatically;
          for one installed by hand, put the key below on that server with
          <span class="mono">saucewg node-pair --peer-key …</span>
        </p>
        <dl class="kv" style="grid-template-columns: 140px 1fr">
          <template v-for="node in state.nodes" :key="node.name">
            <dt>{{ node.name }}</dt>
            <dd class="mono" style="cursor: pointer" title="Click to copy"
                @click="copy(node.public_key, `${node.name} uplink key`)">
              {{ node.public_key || '—' }}
            </dd>
          </template>
        </dl>
      </div>
    </template>
  </template>

  <div v-else class="empty">Loading…</div>

  <!-- Add ------------------------------------------------------------------->
  <ModalShell v-if="adding" wide title="Add an exit node" @close="closeTaskModal">
    <template v-if="!task">
      <p style="margin: 0; color: var(--text-muted); font-size: 13px">
        SauceWG connects to the server as root, installs Docker and AmneziaWG, joins it
        to the cascade and pairs both ends. The password is used for this install only
        and is never stored.
      </p>

      <div class="two-col">
        <div class="field">
          <label>Name</label>
          <input v-model="form.name" type="text" placeholder="eu-nl" />
          <span class="hint">Letters, digits, dot, dash and underscore</span>
        </div>
        <div class="field">
          <label>Server address</label>
          <input v-model="form.host" type="text" placeholder="198.51.100.20" />
          <span class="hint">IP or hostname of the exit server</span>
        </div>
      </div>

      <div class="two-col">
        <div class="field">
          <label>SSH user</label>
          <input v-model="form.ssh_user" type="text" placeholder="root" />
        </div>
        <div class="field">
          <label>SSH port</label>
          <input v-model.number="form.ssh_port" type="number" min="1" max="65535" />
        </div>
      </div>

      <div class="field">
        <label>Root password</label>
        <input v-model="form.ssh_password" type="password" autocomplete="new-password" />
        <span class="hint">
          Used once, over SSH, and discarded when the install finishes. The panel leaves
          its own key on the server, so nothing after this asks for it again.
          <template v-if="panelKey?.enabled">
            Leave it blank if that key is already on the server.
          </template>
        </span>
      </div>

      <div class="row" style="gap: 9px">
        <button class="btn btn-sm" :disabled="busy !== '' || !form.host" @click="checkServer">
          Check the server
        </button>
        <span v-if="probe" class="badge" :class="probe.reachable ? 'badge-active' : 'badge-expired'">
          {{ probe.reachable ? 'reachable' : 'unreachable' }}
        </span>
      </div>

      <div v-if="probe" class="alert" :class="probe.reachable && probe.root ? 'alert-warn' : 'alert-error'">
        <template v-if="!probe.reachable">{{ probe.error }}</template>
        <template v-else-if="!probe.root">
          Connected, but {{ form.ssh_user || 'root' }} cannot act as root on this server.
          Use the root account, or give this one passwordless sudo.
        </template>
        <template v-else>
          {{ probe.os ?? 'unknown OS' }} · {{ probe.cpus }} CPU · {{ probe.memory_mb }} MB RAM ·
          {{ Math.round(probe.disk_free_mb / 1024) }} GB free ·
          {{ probe.docker ? 'Docker present' : 'Docker will be installed' }}
          <template v-if="probe.saucewg">
            · SauceWG is already installed here as {{ probe.role ?? 'a node' }}, and will be
            reconfigured
          </template>
          <template v-if="probe.used_panel_key"> · reached with the panel's key</template>
        </template>
      </div>

      <div class="two-col">
        <div class="field">
          <label>AmneziaWG port</label>
          <input v-model.number="form.port" type="number" min="1" max="65535" />
          <span class="hint">UDP port the entry node dials</span>
        </div>
        <div class="field">
          <label>Priority</label>
          <input v-model.number="form.priority" type="number" min="0" placeholder="auto" />
          <span class="hint">Lower wins; blank appends below every existing node</span>
        </div>
      </div>

      <div class="two-col">
        <div class="field">
          <label>AmneziaWG generation</label>
          <select v-model="form.protocol">
            <option v-for="version in PROTOCOLS" :key="version" :value="version">
              {{ version }}{{ version === '2.0' ? ' — newest' : version === '1.0' ? ' — legacy' : '' }}
            </option>
          </select>
          <span class="hint">
            This is the uplink between the two servers, so it is independent of what
            clients speak. 1.5 and 2.0 obfuscate more but need a recent AmneziaWG build
            on the exit node, which the installer provides.
          </span>
        </div>
        <div class="field">
          <label>Signature packet</label>
          <select v-model="form.signature" :disabled="form.protocol === '1.0'">
            <option v-for="preset in SIGNATURES" :key="preset" :value="preset">{{ preset }}</option>
          </select>
          <span class="hint">
            <template v-if="form.protocol === '1.0'">Not available on 1.0.</template>
            <template v-else>
              Sent ahead of the handshake so a censor sees a protocol it already passes.
            </template>
          </span>
        </div>
      </div>

      <div class="field">
        <label>Pre-shared key</label>
        <input v-model="form.preshared_key" type="text" placeholder="Optional" />
        <span class="hint">
          Adds post-quantum resistance to this uplink. Generate one with
          <span class="mono">docker run --rm --entrypoint awg saucewg/awg genpsk</span>
        </span>
      </div>

      <div class="field">
        <label>Note</label>
        <input v-model="form.note" type="text" placeholder="Optional" />
      </div>
    </template>

    <template v-else>
      <div class="row-between">
        <strong>{{ task.step || 'Starting' }}</strong>
        <span class="badge" :class="task.status === 'failed' ? 'badge-expired' : task.status === 'succeeded' ? 'badge-active' : 'badge-limited'">
          {{ task.status }}
        </span>
      </div>
      <pre class="config">{{ task.log.map((l) => l.text).join('\n') }}</pre>
      <div v-if="task.error" class="alert alert-error">{{ task.error }}</div>
    </template>

    <template #footer>
      <template v-if="!task">
        <button class="btn" @click="adding = false">Cancel</button>
        <button
          class="btn btn-primary"
          :disabled="busy !== '' || !form.name || !form.host || (!form.ssh_password && !panelKey?.enabled)"
          @click="submitAdd"
        >
          Install and add
        </button>
      </template>
      <button v-else class="btn btn-primary" :disabled="taskRunning" @click="closeTaskModal">
        {{ taskRunning ? 'Installing…' : 'Done' }}
      </button>
    </template>
  </ModalShell>

  <!-- Remove ---------------------------------------------------------------->
  <ModalShell v-if="removing" wide :title="`Remove ${removing.name}`" @close="closeTaskModal">
    <template v-if="!task">
      <p style="margin: 0; color: var(--text-muted); font-size: 13px">
        The node leaves the cascade immediately. Clients keep their tunnel to the entry
        node and move to the next healthy exit.
      </p>

      <label v-if="removing.managed" class="switch">
        <input v-model="removeForm.uninstall" type="checkbox" />
        <span>Also remove SauceWG from {{ removing.ssh_host }}</span>
      </label>
      <p v-else style="margin: 0; color: var(--text-dim); font-size: 12.5px">
        This node was not installed from the panel, so nothing is cleaned up on the
        server itself. Run <span class="mono">saucewg uninstall --purge</span> there when
        you are done with it.
      </p>

      <div v-if="removeForm.uninstall && !removing.ssh_key" class="field">
        <label>Root password for {{ removing.ssh_host }}</label>
        <input v-model="removeForm.ssh_password" type="password" autocomplete="new-password" />
        <span class="hint">Credentials are never stored, so they are needed again here</span>
      </div>
      <p
        v-else-if="removeForm.uninstall"
        style="margin: 0; color: var(--text-dim); font-size: 12.5px"
      >
        The panel signs in with its own key, so no password is needed. That key is taken
        back off the server as part of the cleanup.
      </p>
    </template>

    <template v-else>
      <div class="row-between">
        <strong>{{ task.step || 'Starting' }}</strong>
        <span class="badge" :class="task.status === 'failed' ? 'badge-expired' : task.status === 'succeeded' ? 'badge-active' : 'badge-limited'">
          {{ task.status }}
        </span>
      </div>
      <pre class="config">{{ task.log.map((l) => l.text).join('\n') }}</pre>
      <div v-if="task.error" class="alert alert-error">{{ task.error }}</div>
    </template>

    <template #footer>
      <template v-if="!task">
        <button class="btn" @click="removing = null">Cancel</button>
        <button
          class="btn btn-danger"
          :disabled="
            busy !== '' || (removeForm.uninstall && !removeForm.ssh_password && !removing.ssh_key)
          "
          @click="submitRemove"
        >
          Remove
        </button>
      </template>
      <button v-else class="btn btn-primary" :disabled="taskRunning" @click="closeTaskModal">
        {{ taskRunning ? 'Removing…' : 'Done' }}
      </button>
    </template>
  </ModalShell>

  <!-- Repair ---------------------------------------------------------------->
  <ModalShell v-if="repairing" wide :title="`Re-pair ${repairing.name}`" @close="closeTaskModal">
    <template v-if="!task">
      <p style="margin: 0; color: var(--text-muted); font-size: 13px">
        Reinstalls this entry node's uplink key on {{ repairing.ssh_host }} and restarts it.
        Use this when the uplink stays unpaired or never handshakes.
      </p>
      <div class="field">
        <label>Root password for {{ repairing.ssh_host }}</label>
        <input v-model="repairForm.ssh_password" type="password" autocomplete="new-password" />
        <span v-if="repairing.ssh_key" class="hint">
          Optional — the panel has its own key on this server. Fill it in only if that key
          has stopped working, and it will be installed again.
        </span>
      </div>
    </template>

    <template v-else>
      <div class="row-between">
        <strong>{{ task.step || 'Starting' }}</strong>
        <span class="badge" :class="task.status === 'failed' ? 'badge-expired' : task.status === 'succeeded' ? 'badge-active' : 'badge-limited'">
          {{ task.status }}
        </span>
      </div>
      <pre class="config">{{ task.log.map((l) => l.text).join('\n') }}</pre>
      <div v-if="task.error" class="alert alert-error">{{ task.error }}</div>
    </template>

    <template #footer>
      <template v-if="!task">
        <button class="btn" @click="repairing = null">Cancel</button>
        <button
          class="btn btn-primary"
          :disabled="busy !== '' || (!repairForm.ssh_password && !repairing.ssh_key)"
          @click="submitRepair"
        >
          Re-pair
        </button>
      </template>
      <button v-else class="btn btn-primary" :disabled="taskRunning" @click="closeTaskModal">
        {{ taskRunning ? 'Working…' : 'Done' }}
      </button>
    </template>
  </ModalShell>

  <!-- Recover --------------------------------------------------------------->
  <ModalShell v-if="recovering" wide :title="`Recovering ${recovering.name}`" @close="closeTaskModal">
    <p style="margin: 0; color: var(--text-muted); font-size: 13px">
      {{ recovering.ssh_host }} is probed, its service restarted, and the uplink key
      re-installed if the tunnel still does not handshake. Clients are already on another
      exit node, so nothing they are doing is interrupted.
    </p>
    <template v-if="task">
      <div class="row-between" style="margin-top: 14px">
        <strong>{{ task.step || 'Starting' }}</strong>
        <span class="badge" :class="task.status === 'failed' ? 'badge-expired' : task.status === 'succeeded' ? 'badge-active' : 'badge-limited'">
          {{ task.status }}
        </span>
      </div>
      <pre class="config">{{ task.log.map((l) => l.text).join('\n') }}</pre>
      <div v-if="task.error" class="alert alert-error">{{ task.error }}</div>
    </template>

    <template #footer>
      <button class="btn btn-primary" :disabled="taskRunning" @click="closeTaskModal">
        {{ taskRunning ? 'Working…' : 'Done' }}
      </button>
    </template>
  </ModalShell>

  <!-- Protocol -------------------------------------------------------------->
  <ModalShell
    v-if="switching"
    wide
    :title="`AmneziaWG generation for ${switching.name}`"
    @close="closeTaskModal"
  >
    <template v-if="!task">
      <p style="margin: 0; color: var(--text-muted); font-size: 13px">
        {{ switching.ssh_host }} is reconfigured over SSH and the uplink to it is then
        rebuilt with the parameters it reports back — both ends have to pad and label
        packets the same way. The tunnel is down for a few seconds, and clients move to
        the next healthy exit while it is.
      </p>

      <div class="two-col">
        <div class="field">
          <label>Generation</label>
          <select v-model="protocolForm.protocol">
            <option v-for="version in PROTOCOLS" :key="version" :value="version">
              {{ version }}{{ version === (switching.protocol ?? '1.0') ? ' — current' : '' }}
            </option>
          </select>
        </div>
        <div class="field">
          <label>Signature packet</label>
          <select v-model="protocolForm.signature" :disabled="protocolForm.protocol === '1.0'">
            <option v-for="preset in SIGNATURES" :key="preset" :value="preset">{{ preset }}</option>
          </select>
          <span class="hint">
            <template v-if="protocolForm.protocol === '1.0'">Not available on 1.0.</template>
          </span>
        </div>
      </div>

      <div class="field">
        <label>Root password for {{ switching.ssh_host }}</label>
        <input v-model="protocolForm.ssh_password" type="password" autocomplete="new-password" />
        <span class="hint">
          <template v-if="switching.ssh_key">
            Optional — the panel signs in with its own key.
          </template>
          <template v-else>Credentials are never stored, so they are needed again here</template>
        </span>
      </div>

      <p style="margin: 0; color: var(--text-dim); font-size: 12.5px">
        This only changes the uplink between the two servers. What your own clients
        speak is set on the Node page.
      </p>
    </template>

    <template v-else>
      <div class="row-between">
        <strong>{{ task.step || 'Starting' }}</strong>
        <span class="badge" :class="task.status === 'failed' ? 'badge-expired' : task.status === 'succeeded' ? 'badge-active' : 'badge-limited'">
          {{ task.status }}
        </span>
      </div>
      <pre class="config">{{ task.log.map((l) => l.text).join('\n') }}</pre>
      <div v-if="task.error" class="alert alert-error">{{ task.error }}</div>
    </template>

    <template #footer>
      <template v-if="!task">
        <button class="btn" @click="switching = null">Cancel</button>
        <button
          class="btn btn-primary"
          :disabled="
            busy !== '' ||
            (!protocolForm.ssh_password && !switching.ssh_key) ||
            protocolForm.protocol === (switching.protocol ?? '1.0')
          "
          @click="submitProtocol"
        >
          Apply
        </button>
      </template>
      <button v-else class="btn btn-primary" :disabled="taskRunning" @click="closeTaskModal">
        {{ taskRunning ? 'Working…' : 'Done' }}
      </button>
    </template>
  </ModalShell>

  <!-- Manage ---------------------------------------------------------------->
  <ModalShell v-if="managing" wide :title="`Manage ${managing.name}`" @close="closeTaskModal">
    <template v-if="!task">
      <p style="margin: 0; color: var(--text-muted); font-size: 13px">
        {{ managing.ssh_host }}, as the server itself reports it. Everything here runs
        over SSH with the panel's own key.
      </p>

      <div v-if="remote && !remote.reachable" class="alert alert-error">{{ remote.error }}</div>

      <template v-else-if="remote">
        <dl class="kv" style="grid-template-columns: 140px 1fr">
          <dt>Host</dt>
          <dd>{{ remote.os ?? '—' }} · {{ remote.arch ?? '—' }} · {{ remote.cpus }} CPU</dd>
          <dt>Uptime</dt>
          <dd>{{ duration(remote.uptime_seconds) }}</dd>
          <dt>Disk free</dt>
          <dd>{{ bytes(remote.disk_free_mb * 1024 * 1024) }}</dd>
          <dt>SauceWG</dt>
          <dd class="mono">{{ remote.cli_version ?? 'unknown' }} · {{ remote.dir ?? '—' }}</dd>
          <dt>Containers</dt>
          <dd>
            <div v-for="container in remote.containers" :key="container.name" class="row" style="gap: 9px">
              <i class="dot" :class="{ on: container.state === 'running' }"></i>
              <span class="mono">{{ container.name }}</span>
              <span style="color: var(--text-dim)">{{ container.status }}</span>
            </div>
            <span v-if="!remote.containers.length" style="color: var(--text-dim)">
              nothing is running on this server
            </span>
          </dd>
        </dl>
      </template>

      <div v-else class="empty" style="margin: 0">Asking the server…</div>

      <div class="row" style="gap: 9px; flex-wrap: wrap">
        <button class="btn btn-sm" :disabled="busy !== ''" @click="loadStatus">Refresh</button>
        <button class="btn btn-sm" :disabled="busy !== ''" @click="service('restart')">Restart</button>
        <button class="btn btn-sm" :disabled="busy !== ''" @click="service('stop')">Stop</button>
        <button class="btn btn-sm" :disabled="busy !== ''" @click="service('start')">Start</button>
        <button class="btn btn-sm" :disabled="busy !== ''" @click="upgrade">Upgrade</button>
        <button class="btn btn-sm" :disabled="busy !== ''" @click="loadLogs('awg')">Node log</button>
      </div>

      <pre v-if="logs" class="config" style="max-height: 320px">{{ logs }}</pre>
    </template>

    <template v-else>
      <div class="row-between">
        <strong>{{ task.step || 'Starting' }}</strong>
        <span class="badge" :class="task.status === 'failed' ? 'badge-expired' : task.status === 'succeeded' ? 'badge-active' : 'badge-limited'">
          {{ task.status }}
        </span>
      </div>
      <pre class="config">{{ task.log.map((l) => l.text).join('\n') }}</pre>
      <div v-if="task.error" class="alert alert-error">{{ task.error }}</div>
    </template>

    <template #footer>
      <button class="btn btn-primary" :disabled="taskRunning" @click="closeTaskModal">
        {{ taskRunning ? 'Working…' : 'Done' }}
      </button>
    </template>
  </ModalShell>

  <!-- Edit ------------------------------------------------------------------>
  <ModalShell v-if="editing" :title="`Edit ${editing.name}`" @close="editing = null">
    <div class="field">
      <label>Priority</label>
      <input v-model.number="editForm.priority" type="number" min="0" />
      <span class="hint">
        Lower wins. Changing it only moves the route — the tunnel is never rebuilt.
      </span>
    </div>
    <div class="field">
      <label>Note</label>
      <input v-model="editForm.note" type="text" placeholder="Optional" />
    </div>
    <template #footer>
      <button class="btn" @click="editing = null">Cancel</button>
      <button class="btn btn-primary" @click="submitEdit">Save</button>
    </template>
  </ModalShell>
</template>
