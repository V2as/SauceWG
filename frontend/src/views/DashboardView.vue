<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { api, type SystemStats, type UsageSeries } from '../api'
import TrafficChart from '../components/TrafficChart.vue'
import { bytes, dateTime, duration, percent, relativeTime, speed } from '../utils/format'

const stats = ref<SystemStats | null>(null)
const usage = ref<UsageSeries | null>(null)
const hours = ref(24)
const error = ref('')
let timer: number | undefined

async function refresh() {
  try {
    const [system, series] = await Promise.all([api.system(), api.nodeUsage(hours.value)])
    stats.value = system
    usage.value = series
    error.value = ''
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  }
}

function meterClass(value: number) {
  if (value >= 90) return 'meter danger'
  if (value >= 75) return 'meter warn'
  return 'meter'
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
      <h1>Dashboard</h1>
      <p>Live view of the entry node and the cascade uplink</p>
    </div>
    <select v-model.number="hours" style="width: auto" @change="refresh">
      <option :value="6">Last 6 hours</option>
      <option :value="24">Last 24 hours</option>
      <option :value="168">Last 7 days</option>
      <option :value="720">Last 30 days</option>
    </select>
  </div>

  <div v-if="error" class="alert alert-error" style="margin-bottom: 14px">{{ error }}</div>

  <template v-if="stats">
    <div
      v-if="!stats.node_ready"
      class="alert alert-warn"
      style="margin-bottom: 14px"
    >
      The AmneziaWG node has not published its parameters yet. Client configs are unavailable
      until the node container finishes starting.
    </div>

    <div class="grid grid-4" style="margin-bottom: 14px">
      <div class="card">
        <div class="stat-label">Clients online</div>
        <div class="stat-value">{{ stats.clients_online }}</div>
        <div class="stat-sub">{{ stats.clients_active }} active / {{ stats.clients_total }} total</div>
      </div>

      <div class="card">
        <div class="stat-label">Throughput</div>
        <div class="stat-value">{{ speed(stats.incoming_speed + stats.outgoing_speed) }}</div>
        <div class="stat-sub">
          ↑ {{ speed(stats.incoming_speed) }} · ↓ {{ speed(stats.outgoing_speed) }}
        </div>
      </div>

      <div class="card">
        <div class="stat-label">Total traffic</div>
        <div class="stat-value">{{ bytes(stats.total_up + stats.total_down) }}</div>
        <div class="stat-sub">↑ {{ bytes(stats.total_up) }} · ↓ {{ bytes(stats.total_down) }}</div>
      </div>

      <div class="card">
        <div class="stat-label">Cascade</div>
        <div class="stat-value row" style="gap: 9px">
          <i class="dot" :class="{ on: stats.cascade.connected }"></i>
          <span>{{ stats.cascade.node ?? (stats.cascade.connected ? 'Connected' : 'Down') }}</span>
        </div>
        <div v-if="stats.cascade.stalled" class="stat-sub" style="color: var(--danger)">
          routed here but not handshaking — clients are getting nowhere
        </div>
        <div v-else class="stat-sub">
          exit {{ stats.cascade.exit_ip ?? 'unknown' }}
          <template v-if="stats.cascade.nodes_total > 1">
            · {{ stats.cascade.nodes_healthy }}/{{ stats.cascade.nodes_total }} nodes up
          </template>
        </div>
      </div>
    </div>

    <div class="grid grid-2" style="margin-bottom: 14px">
      <div class="card">
        <div class="row-between" style="margin-bottom: 12px">
          <div class="stat-label">Traffic</div>
          <div style="color: var(--text-dim); font-size: 12px">
            ↑ {{ bytes(usage?.total_up ?? 0) }} · ↓ {{ bytes(usage?.total_down ?? 0) }}
          </div>
        </div>
        <TrafficChart :points="usage?.points ?? []" />
      </div>

      <div class="card">
        <div class="stat-label" style="margin-bottom: 14px">Host</div>

        <div style="margin-bottom: 14px">
          <div class="row-between" style="font-size: 13px">
            <span>CPU · {{ stats.cpu_cores }} cores</span>
            <span>{{ stats.cpu_percent.toFixed(0) }}%</span>
          </div>
          <div :class="meterClass(stats.cpu_percent)"><span :style="{ width: `${stats.cpu_percent}%` }"></span></div>
        </div>

        <div style="margin-bottom: 14px">
          <div class="row-between" style="font-size: 13px">
            <span>Memory</span>
            <span>{{ bytes(stats.mem_used) }} / {{ bytes(stats.mem_total) }}</span>
          </div>
          <div :class="meterClass(percent(stats.mem_used, stats.mem_total))">
            <span :style="{ width: `${percent(stats.mem_used, stats.mem_total)}%` }"></span>
          </div>
        </div>

        <div style="margin-bottom: 14px">
          <div class="row-between" style="font-size: 13px">
            <span>Disk</span>
            <span>{{ bytes(stats.disk_used) }} / {{ bytes(stats.disk_total) }}</span>
          </div>
          <div :class="meterClass(percent(stats.disk_used, stats.disk_total))">
            <span :style="{ width: `${percent(stats.disk_used, stats.disk_total)}%` }"></span>
          </div>
        </div>

        <div class="stat-sub">Uptime {{ duration(stats.uptime_seconds) }}</div>
      </div>
    </div>

    <div class="card">
      <div class="stat-label" style="margin-bottom: 14px">Cascade uplink</div>
      <dl class="kv">
        <dt>Entry endpoint</dt>
        <dd class="mono">{{ stats.endpoint }}</dd>
        <dt>Entry public key</dt>
        <dd class="mono">{{ stats.server_public_key || '—' }}</dd>
        <dt>Active exit node</dt>
        <dd>
          <RouterLink to="/exit-nodes">{{ stats.cascade.node ?? '—' }}</RouterLink>
          <span style="color: var(--text-dim)">
            ({{ stats.cascade.mode }}, {{ stats.cascade.nodes_healthy }}/{{ stats.cascade.nodes_total }} healthy)
          </span>
        </dd>
        <dt>Uplink interface</dt>
        <dd class="mono">{{ stats.cascade.iface }}</dd>
        <dt>Exit endpoint</dt>
        <dd class="mono">
          {{ stats.cascade.endpoint ?? '—' }}
          <span v-if="stats.cascade.endpoint_family" style="color: var(--text-dim)">
            (IPv{{ stats.cascade.endpoint_family }})
          </span>
        </dd>
        <!-- Only once the link to the exit nodes carries IPv6; an IPv4-only cascade,
             which is the default, has nothing to report here. -->
        <dt v-if="stats.cascade.bridge_subnet6">IPv6 through the cascade</dt>
        <dd v-if="stats.cascade.bridge_subnet6">
          <span :style="stats.cascade.healthy6 ? '' : 'color: var(--warn)'">
            {{ stats.cascade.healthy6 ? 'reachable' : 'not reachable' }}
          </span>
          <span style="color: var(--text-dim)">
            · {{ stats.cascade.nodes_healthy6 }}/{{ stats.cascade.nodes_total }} nodes
            · bridge <span class="mono">{{ stats.cascade.bridge_subnet6 }}</span>
          </span>
        </dd>
        <dt>Exit public key</dt>
        <dd class="mono">{{ stats.cascade.peer_public_key ?? '—' }}</dd>
        <dt>Last handshake</dt>
        <dd>
          {{ relativeTime(stats.cascade.last_handshake_at) }}
          <span style="color: var(--text-dim)">({{ dateTime(stats.cascade.last_handshake_at) }})</span>
        </dd>
        <dt>Uplink traffic</dt>
        <dd>↑ {{ bytes(stats.cascade.rx_bytes) }} · ↓ {{ bytes(stats.cascade.tx_bytes) }}</dd>
        <dt>Past the cascade</dt>
        <dd>
          <RouterLink to="/routing">{{ stats.cascade.direct_routes }}</RouterLink>
          <span style="color: var(--text-dim)"> destinations leaving through this server</span>
        </dd>
        <dt>Reopened here</dt>
        <dd>
          <template v-if="stats.cascade.bypass_active">
            <RouterLink to="/routing">{{ stats.cascade.bypass_routes }}</RouterLink>
            <span style="color: var(--text-dim)"> destinations being dialled from this server</span>
          </template>
          <span v-else style="color: var(--text-dim)">
            not engaged — client traffic is leaving through an exit node
          </span>
        </dd>
      </dl>
    </div>
  </template>

  <div v-else class="empty">Loading…</div>
</template>
