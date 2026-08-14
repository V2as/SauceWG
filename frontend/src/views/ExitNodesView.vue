<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api, type ExitNode, type ExitNodeList } from '../api'
import { notify } from '../store'
import { bytes, dateTime, relativeTime } from '../utils/format'

const state = ref<ExitNodeList | null>(null)
const busy = ref('')
const error = ref('')
let timer: number | undefined

const healthy = computed(() => state.value?.nodes.filter((n) => n.healthy).length ?? 0)

async function refresh() {
  try {
    state.value = await api.exitNodes()
    error.value = ''
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
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

function statusLabel(node: ExitNode) {
  if (!node.paired) return { text: 'unpaired', klass: 'badge-limited' }
  if (node.active) return { text: 'active', klass: 'badge-active' }
  if (node.healthy) return { text: 'standby', klass: 'badge-disabled' }
  return { text: 'down', klass: 'badge-expired' }
}

onMounted(() => {
  refresh()
  timer = window.setInterval(refresh, 5000)
})
onUnmounted(() => window.clearInterval(timer))
</script>

<template>
  <div class="page-head">
    <div>
      <h1>Exit nodes</h1>
      <p>Every configured exit node stays connected; only one carries client traffic</p>
    </div>
    <button
      class="btn"
      :disabled="busy !== '' || state?.mode === 'auto'"
      @click="auto"
    >
      {{ state?.mode === 'auto' ? 'Automatic failover on' : 'Return to automatic' }}
    </button>
  </div>

  <div v-if="error" class="alert alert-error" style="margin-bottom: 14px">{{ error }}</div>

  <template v-if="state">
    <div v-if="state.stale" class="alert alert-warn" style="margin-bottom: 14px">
      The node container has not refreshed its uplink state since
      {{ dateTime(state.updated_at) }}. The health data below is stale and failover is
      probably not running.
    </div>

    <div v-if="!state.nodes.length" class="empty">
      No exit node is configured. Add one to <span class="mono">config/exit-nodes.json</span>
      and restart the node container.
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
          <div class="stat-label">Kill switch</div>
          <div class="stat-value row" style="gap: 9px">
            <i class="dot" :class="{ on: state.killswitch }"></i>
            <span>{{ state.killswitch ? 'Armed' : 'Off' }}</span>
          </div>
          <div class="stat-sub">
            {{ state.killswitch ? 'clients drop when every uplink is down' : 'traffic may leave via the entry IP' }}
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
                <div class="mono" style="color: var(--text-dim)">{{ node.address }}</div>
              </td>
              <td>
                <span class="badge" :class="statusLabel(node).klass">{{ statusLabel(node).text }}</span>
              </td>
              <td class="mono">{{ node.priority }}</td>
              <td class="mono">{{ node.endpoint ?? '—' }}</td>
              <td class="mono">{{ node.iface }}</td>
              <td class="mono">{{ node.latency_ms != null ? `${node.latency_ms.toFixed(1)} ms` : '—' }}</td>
              <td :title="dateTime(node.last_handshake_at)">{{ relativeTime(node.last_handshake_at) }}</td>
              <td>↑ {{ bytes(node.rx_bytes) }} · ↓ {{ bytes(node.tx_bytes) }}</td>
              <td style="text-align: right">
                <button
                  class="btn btn-sm"
                  :disabled="busy !== '' || node.active || !node.paired"
                  @click="activate(node)"
                >
                  Switch here
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="card" style="margin-top: 14px">
        <div class="stat-label" style="margin-bottom: 14px">Pairing keys</div>
        <p style="color: var(--text-dim); font-size: 12.5px; margin-top: 0">
          Each uplink has its own key pair. Install the key below on the matching exit node as
          <span class="mono">AWG_PEER_PUBLIC_KEY</span>, then restart it.
        </p>
        <dl class="kv" style="grid-template-columns: 140px 1fr">
          <template v-for="node in state.nodes" :key="node.name">
            <dt>{{ node.name }}</dt>
            <dd class="mono">{{ node.public_key || '—' }}</dd>
          </template>
        </dl>
      </div>
    </template>
  </template>

  <div v-else class="empty">Loading…</div>
</template>
