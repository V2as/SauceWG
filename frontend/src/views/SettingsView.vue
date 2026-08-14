<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { api, type CascadeStatus, type NodeSettings } from '../api'
import { notify } from '../store'
import { bytes, dateTime, relativeTime } from '../utils/format'

const settings = ref<NodeSettings | null>(null)
const cascade = ref<CascadeStatus | null>(null)
const syncing = ref(false)

const LEGACY_ORDER = ['JC', 'JMIN', 'JMAX', 'S1', 'S2', 'H1', 'H2', 'H3', 'H4']

async function load() {
  try {
    const [node, system] = await Promise.all([api.settings(), api.system()])
    settings.value = node
    cascade.value = system.cascade
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

async function forceSync() {
  syncing.value = true
  try {
    const result = await api.forceSync()
    notify(`Sync done: +${result.added} ~${result.updated} -${result.removed}`, 'success')
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    syncing.value = false
  }
}

onMounted(load)
</script>

<template>
  <div class="page-head">
    <div>
      <h1>Node</h1>
      <p>AmneziaWG legacy parameters served to clients</p>
    </div>
    <button class="btn" :disabled="syncing" @click="forceSync">
      {{ syncing ? 'Syncing…' : 'Force peer sync' }}
    </button>
  </div>

  <div v-if="settings" class="grid grid-2">
    <div class="card">
      <div class="stat-label" style="margin-bottom: 14px">Entry interface</div>
      <dl class="kv">
        <dt>Interface</dt>
        <dd class="mono">{{ settings.iface }}</dd>
        <dt>Public key</dt>
        <dd class="mono">{{ settings.server_public_key || '—' }}</dd>
        <dt>Endpoint</dt>
        <dd class="mono">{{ settings.endpoint_host }}:{{ settings.endpoint_port }}</dd>
        <dt>Listen port</dt>
        <dd class="mono">{{ settings.listen_port }}</dd>
        <dt>Subnet</dt>
        <dd class="mono">{{ settings.subnet }}</dd>
        <dt>Node address</dt>
        <dd class="mono">{{ settings.address }}</dd>
        <dt>Server MTU</dt>
        <dd class="mono">{{ settings.mtu }}</dd>
      </dl>
    </div>

    <div class="card">
      <div class="stat-label" style="margin-bottom: 14px">Obfuscation (AmneziaWG legacy)</div>
      <dl class="kv" style="grid-template-columns: 90px 1fr">
        <template v-for="key in LEGACY_ORDER" :key="key">
          <dt>{{ key }}</dt>
          <dd class="mono">{{ settings.obfuscation[key] ?? '—' }}</dd>
        </template>
      </dl>
      <p style="color: var(--text-dim); font-size: 12px; margin-bottom: 0">
        S1, S2 and H1–H4 must match on both sides of the tunnel, so they are copied verbatim into
        every client config. Jc/Jmin/Jmax only affect the sending side.
      </p>
    </div>

    <div class="card">
      <div class="stat-label" style="margin-bottom: 14px">Client profile defaults</div>
      <dl class="kv">
        <dt>DNS</dt>
        <dd class="mono">{{ settings.client_dns }}</dd>
        <dt>MTU</dt>
        <dd class="mono">{{ settings.client_mtu }}</dd>
        <dt>Allowed IPs</dt>
        <dd class="mono">{{ settings.client_allowed_ips }}</dd>
      </dl>
    </div>

    <div v-if="cascade" class="card">
      <div class="stat-label" style="margin-bottom: 14px">Cascade uplink</div>
      <dl class="kv">
        <dt>State</dt>
        <dd>
          <span class="badge" :class="cascade.connected ? 'badge-active' : 'badge-expired'">
            {{ cascade.enabled ? (cascade.connected ? 'connected' : 'down') : 'disabled' }}
          </span>
        </dd>
        <dt>Interface</dt>
        <dd class="mono">{{ cascade.iface }}</dd>
        <dt>Exit endpoint</dt>
        <dd class="mono">{{ cascade.endpoint ?? '—' }}</dd>
        <dt>Exit public key</dt>
        <dd class="mono">{{ cascade.peer_public_key ?? '—' }}</dd>
        <dt>Last handshake</dt>
        <dd :title="dateTime(cascade.last_handshake_at)">{{ relativeTime(cascade.last_handshake_at) }}</dd>
        <dt>Traffic</dt>
        <dd>↑ {{ bytes(cascade.rx_bytes) }} · ↓ {{ bytes(cascade.tx_bytes) }}</dd>
      </dl>
    </div>
  </div>

  <div v-else class="empty">Loading…</div>
</template>
