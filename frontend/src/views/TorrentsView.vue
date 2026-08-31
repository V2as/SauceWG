<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api, type TorrentStatus } from '../api'
import { notify } from '../store'
import { duration } from '../utils/format'

const state = ref<TorrentStatus | null>(null)
const error = ref('')
const busy = ref('')
let timer: number | undefined

// Named for what an operator would call them rather than for the rule that
// implements them, and ordered so the ones that decide whether a swarm ever
// learns this node's address come first.
const LAYERS: { key: string; label: string; hint: string }[] = [
  { key: 'dht', label: 'DHT', hint: 'Peer lookups over the distributed hash table' },
  { key: 'tracker', label: 'Trackers', hint: 'Announces and scrapes, over UDP and HTTP' },
  { key: 'utp', label: 'uTP', hint: 'Peer connections opening over UDP, matched by shape' },
  { key: 'handshake', label: 'Peer handshakes', hint: 'The unencrypted BitTorrent handshake' },
  { key: 'pex', label: 'Peer exchange', hint: 'Extension messages that hand out more peers' },
  { key: 'peer', label: 'Known peers', hint: 'Addresses already caught, dropped on sight' },
  { key: 'port', label: 'Default ports', hint: '6881-6889, 6969 and 51413' },
  { key: 'lsd', label: 'Local discovery', hint: 'BT-SEARCH sent somewhere routable' },
  { key: 'dns', label: 'Tracker lookups', hint: 'DNS queries for known tracker names' },
  { key: 'metainfo', label: '.torrent files', hint: 'Metainfo on its way back to a client' },
  { key: 'strict-tcp', label: 'TCP to closed ports', hint: 'Strict mode only' },
  { key: 'strict-udp', label: 'UDP to closed ports', hint: 'Strict mode only' },
]

const total = computed(() => state.value?.blocked?.total ?? 0)

const layers = computed(() =>
  LAYERS.map((layer) => ({ ...layer, count: state.value?.blocked?.[layer.key] ?? 0 })).filter(
    (layer) => layer.count > 0,
  ),
)

/** What the node is doing right now, in the words the switch above is set in. */
const summary = computed(() => {
  const status = state.value
  if (!status) return ''
  if (!status.live) return 'The node container is not reporting'
  if (!status.enabled) return 'Torrent traffic is forwarded like anything else'
  if (!status.active) return 'Turned on, waiting for the node to apply it'
  return status.active_mode === 'strict' ? 'Strict: everything below is refused' : 'Blocking'
})

const strict = computed(() => state.value?.mode === 'strict')

async function refresh() {
  try {
    state.value = await api.torrents()
    error.value = ''
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  }
}

async function toggle() {
  if (!state.value) return
  const next = !state.value.enabled
  busy.value = 'enabled'
  try {
    state.value = await api.setTorrents({ enabled: next })
    notify(
      next ? 'Torrent traffic is now blocked on this node' : 'Torrent traffic is no longer blocked',
      next ? 'success' : 'error',
    )
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function setMode(mode: 'on' | 'strict') {
  if (!state.value || state.value.mode === mode) return
  if (
    mode === 'strict' &&
    !confirm(
      'Strict mode refuses outbound TCP and UDP except to the ports listed below. ' +
        'That closes encrypted peer traffic on unusual ports, and it will also break ' +
        'any service that uses a port nobody named — including a VPN a client runs ' +
        'inside the tunnel. Continue?',
    )
  ) {
    return
  }
  busy.value = 'mode'
  try {
    state.value = await api.setTorrents({ mode })
    notify(mode === 'strict' ? 'Strict mode is in force' : 'Back to the standard mode', 'success')
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

onMounted(() => {
  refresh()
  timer = window.setInterval(refresh, 10000)
})
onUnmounted(() => window.clearInterval(timer))
</script>

<template>
  <div class="page-head">
    <div>
      <h1>Torrents</h1>
      <p>BitTorrent, blocked in the traffic this node forwards</p>
    </div>
    <label v-if="state" class="switch">
      <input
        type="checkbox"
        :checked="state.enabled"
        :disabled="!state.editable || busy !== ''"
        @change="toggle"
      />
      <span>{{ state.enabled ? 'Blocking' : 'Off' }}</span>
    </label>
  </div>

  <div v-if="error" class="alert alert-error" style="margin-bottom: 14px">{{ error }}</div>

  <template v-if="state">
    <div v-if="state.config_error" class="alert alert-warn" style="margin-bottom: 14px">
      {{ state.config_error }}
    </div>

    <div v-else-if="state.enabled && !state.live" class="alert alert-warn" style="margin-bottom: 14px">
      The node container is not reporting, so nothing here is confirmed to be in
      effect. It may be stopped, or older than this feature.
    </div>

    <div v-if="!state.enabled" class="alert alert-error" style="margin-bottom: 14px">
      Torrent traffic is leaving through whichever server is carrying this node's
      traffic out. A swarm sees that server's address, and a datacentre answers a
      copyright notice by suspending it — taking every client on it down at once.
    </div>

    <div class="grid grid-4" style="margin-bottom: 14px">
      <div class="card">
        <div class="stat-label">Packets dropped</div>
        <div class="stat-value">{{ total.toLocaleString() }}</div>
        <div class="stat-sub">{{ summary }}</div>
      </div>

      <div class="card">
        <div class="stat-label">Mode</div>
        <div class="stat-value" style="font-size: 20px">{{ strict ? 'Strict' : 'Standard' }}</div>
        <div class="stat-sub">
          {{ strict ? 'signatures plus a port policy' : 'signatures and known peers' }}
        </div>
      </div>

      <div class="card">
        <div class="stat-label">Peers blacklisted</div>
        <div class="stat-value">{{ state.peers.toLocaleString() }}</div>
        <div class="stat-sub">addresses dropped on sight for an hour</div>
      </div>

      <div class="card">
        <div class="stat-label">Clients caught</div>
        <div class="stat-value">{{ state.clients.length }}</div>
        <div class="stat-sub">
          {{ state.clients.length ? 'in the last day' : 'nobody has tried' }}
        </div>
      </div>
    </div>

    <div class="card" style="margin-bottom: 14px">
      <div class="row-between" style="margin-bottom: 14px">
        <div class="stat-label" style="margin: 0">How hard to block</div>
        <div class="row" style="gap: 6px">
          <button
            class="btn btn-sm"
            :class="!strict ? 'btn-primary' : ''"
            :disabled="!state.editable || busy !== ''"
            @click="setMode('on')"
          >
            Standard
          </button>
          <button
            class="btn btn-sm"
            :class="strict ? 'btn-primary' : ''"
            :disabled="!state.editable || busy !== ''"
            @click="setMode('strict')"
          >
            Strict
          </button>
        </div>
      </div>

      <p style="color: var(--text-dim); font-size: 12.5px; margin: 0 0 10px">
        <strong style="color: var(--text)">Standard</strong> kills peer discovery —
        DHT, trackers, peer exchange and local discovery — on signatures no client can
        drop and still work, matches peer connections by the shape of their opening
        packet before encryption starts, and remembers every address it catches so the
        next connection to that peer dies without being read. A client cannot find a
        swarm, and the swarm never learns this node's address.
      </p>
      <p style="color: var(--text-dim); font-size: 12.5px; margin: 0">
        <strong style="color: var(--text)">Strict</strong> adds the one thing
        signatures cannot cover: an encrypted connection to an address the client
        already had. Outbound TCP and UDP are refused except to the ports real services
        answer on, so there is nowhere left for it to go. It will also break anything
        using a port nobody named — including a VPN a client runs inside the tunnel,
        which is deliberate, since that would carry torrents where nothing downstream
        could ever see them.
      </p>
    </div>

    <div v-if="state.enabled && state.live && !state.capabilities.ipset" class="alert alert-warn" style="margin-bottom: 14px">
      This host's kernel has no ipset support, so an address caught speaking
      BitTorrent is not remembered. Each connection is judged on its own, which
      misses an encrypted reconnection to a peer already known.
    </div>

    <template v-if="state.clients.length">
      <div class="page-head" style="margin-top: 22px">
        <div>
          <h1 style="font-size: 20px">Who has been trying</h1>
          <p>Clients whose traffic the guard has dropped, most persistent first</p>
        </div>
      </div>

      <div class="table-wrap">
        <table style="min-width: 560px">
          <thead>
            <tr>
              <th class="plain">Client</th>
              <th class="plain">Address</th>
              <th class="plain">Packets dropped</th>
              <th class="plain">Drops off in</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="offender in state.clients" :key="offender.address">
              <td style="font-weight: 550">
                {{ offender.name ?? '—' }}
                <span v-if="!offender.name" class="stat-sub" style="margin-left: 6px">
                  not a current client
                </span>
              </td>
              <td class="mono">{{ offender.address }}</td>
              <td>{{ offender.packets.toLocaleString() }}</td>
              <td>{{ offender.expires_in ? duration(offender.expires_in) : '—' }}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p class="stat-sub" style="margin: 10px 0 0">
        Nothing here is blocked for being on this list — it is what the guard caught,
        kept for a day so there is somebody to talk to. A client with a large count is
        a torrent client that has not been told to stop, retrying the peers of a swarm
        it will never reach.
      </p>
    </template>

    <template v-if="layers.length">
      <div class="page-head" style="margin-top: 22px">
        <div>
          <h1 style="font-size: 20px">What is being caught</h1>
          <p>Packets dropped by each layer since the node last started</p>
        </div>
      </div>

      <div class="table-wrap">
        <table style="min-width: 520px">
          <thead>
            <tr>
              <th class="plain">Layer</th>
              <th class="plain">Packets</th>
              <th class="plain">What it is</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="layer in layers" :key="layer.key">
              <td style="font-weight: 550">{{ layer.label }}</td>
              <td>{{ layer.count.toLocaleString() }}</td>
              <td class="stat-sub">{{ layer.hint }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>

    <div v-else-if="state.enabled && state.live" class="empty" style="margin-top: 22px">
      Nothing has been caught yet. The rules are installed ({{ state.rules }} of them
      on the forwarding path); this is what a node with no torrent client on it looks
      like.
    </div>

    <div class="card" style="margin-top: 14px">
      <div class="stat-label" style="margin-bottom: 14px">Why this is a switch and not a list</div>
      <p style="color: var(--text-dim); font-size: 12.5px; margin-top: 0">
        BitTorrent has no fixed address to block. Peers are discovered at runtime and
        the connection to them is encrypted from its first byte, so a list of ranges
        would be out of date before it was saved. What cannot change is the protocol:
        a DHT query is bencoded text, a tracker announce opens with a fixed constant,
        and a peer connection starts with a header of a known shape. Those are matched
        on the forwarding path of this node — the one place a client's traffic exists
        as plain IP, after the tunnel has decrypted it and before anything re-encrypts
        it.
      </p>
      <p style="color: var(--text-dim); font-size: 12.5px; margin-bottom: 0">
        Changes apply within a second, without disturbing any tunnel. Connections that
        were already open are dropped when the guard is turned on, so a torrent running
        at that moment stops rather than finishing.
      </p>
    </div>
  </template>
</template>
