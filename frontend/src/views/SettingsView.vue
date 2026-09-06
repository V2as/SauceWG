<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { api, type CascadeStatus, type NodeSettings } from '../api'
import { notify } from '../store'
import { bytes, dateTime, relativeTime } from '../utils/format'

const settings = ref<NodeSettings | null>(null)
const cascade = ref<CascadeStatus | null>(null)
const syncing = ref(false)

// The order a .conf lists them. Only the ones the generation in force carries come
// back from the API, so this doubles as the filter.
const PARAM_ORDER = [
  'JC', 'JMIN', 'JMAX',
  'S1', 'S2', 'S3', 'S4',
  'H1', 'H2', 'H3', 'H4',
  'I1', 'I2', 'I3', 'I4', 'I5',
]

const LABELS: Record<string, string> = { JC: 'Jc', JMIN: 'Jmin', JMAX: 'Jmax' }

// What a client needs in order to load a profile of this generation at all.
const REQUIREMENTS: Record<string, string> = {
  '1.0': 'Loads on any KeeneticOS from 4.2 Alpha 2 on, and on every AmneziaVPN build.',
  '1.5': 'Needs KeeneticOS 5.1 Alpha 3 or newer on a router, or AmneziaVPN 4.8.12.9 or newer.',
  '2.0': 'Needs KeeneticOS 5.1 Alpha 3 or newer on a router, or AmneziaVPN 4.8.12.9 or newer.',
}

const presentParams = computed(() =>
  PARAM_ORDER.filter((key) => settings.value?.obfuscation[key])
)

// The AmneziaVPN app does not pass non-zero S3/S4 to its own backend, so it never strips
// the padding this node adds: the handshake completes and no traffic flows. Routers using
// the kernel module are unaffected, so this is a warning rather than a misconfiguration.
const appPaddingWarning = computed(() => {
  const obf = settings.value?.obfuscation
  if (!obf) return false
  return ['S3', 'S4'].some((key) => Number(obf[key] ?? 0) > 0)
})

// `down` and `stalled` both mean no client traffic is leaving through the cascade;
// the difference is that a stalled one has an exit node assigned and failing to carry
// it, which is a fault rather than an absence.
const cascadeState = computed(() => {
  const state = cascade.value
  if (!state || !state.enabled) return 'disabled'
  if (state.connected) return 'connected'
  return state.stalled ? 'stalled' : 'down'
})

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
      <p>AmneziaWG parameters served to clients</p>
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
        <dt>Protocol</dt>
        <dd>
          <span class="badge badge-active">AmneziaWG {{ settings.protocol }}</span>
        </dd>
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
      <div class="stat-label" style="margin-bottom: 14px">
        Obfuscation (AmneziaWG {{ settings.protocol }})
      </div>
      <dl class="kv" style="grid-template-columns: 90px 1fr">
        <template v-for="key in presentParams" :key="key">
          <dt>{{ LABELS[key] ?? key }}</dt>
          <dd class="mono wrap">{{ settings.obfuscation[key] }}</dd>
        </template>
      </dl>
      <p style="color: var(--text-dim); font-size: 12px; margin-bottom: 6px">
        Which parameters are present is what makes this a {{ settings.protocol }} profile.
        S1–S4 and H1–H4 must match on both sides of the tunnel, so they are copied verbatim into
        every client config. Jc/Jmin/Jmax and I1–I5 only affect the sending side.
      </p>
      <p style="color: var(--text-dim); font-size: 12px; margin-bottom: 0">
        {{ REQUIREMENTS[settings.protocol] }}
        Change it with <code>saucewg set-protocol</code> on this server; every client config should
        then be re-exported and re-imported so it declares the same generation.
      </p>
      <p v-if="appPaddingWarning" class="note-warn">
        This interface pads transport packets, which the default leaves at zero. AmneziaVPN app
        users will connect and pass no traffic: the app does not hand non-zero S3/S4 to its own
        backend, so it never strips the padding. Unless every client here is a router, set
        <code>AWG_S3=0</code> and <code>AWG_S4=0</code> in <code>.env</code> and restart — the
        profile stays {{ settings.protocol }} either way.
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
            {{ cascadeState }}
          </span>
          <div v-if="cascade.stalled" class="stat-sub" style="margin-top: 4px">
            {{ cascade.node ?? 'the active exit node' }} is still being routed to, and has
            stopped handshaking
          </div>
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
