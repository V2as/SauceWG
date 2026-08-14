<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { api, qrUrl, type Client } from '../api'
import ModalShell from '../components/ModalShell.vue'
import { notify } from '../store'
import { bytes, dateTime, percent, relativeTime, untilTime } from '../utils/format'

const items = ref<Client[]>([])
const total = ref(0)
const loading = ref(false)
const search = ref('')
const statusFilter = ref('')
const sort = ref('created_at')
const order = ref<'asc' | 'desc'>('desc')
const offset = ref(0)
const limit = 50
let timer: number | undefined
let searchTimer: number | undefined

const editing = ref<Client | null>(null)
const creating = ref(false)
const viewing = ref<Client | null>(null)
const configText = ref('')

const form = ref({
  name: '',
  data_limit_gb: 0,
  reset_strategy: 'no_reset',
  expire_in_days: 0,
  enabled: true,
  note: '',
})

const pages = computed(() => Math.max(1, Math.ceil(total.value / limit)))
const page = computed(() => Math.floor(offset.value / limit) + 1)

async function load() {
  loading.value = true
  try {
    const data = await api.clients({
      search: search.value,
      status: statusFilter.value,
      sort: sort.value,
      order: order.value,
      offset: offset.value,
      limit,
    })
    items.value = data.items
    total.value = data.total
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    loading.value = false
  }
}

function sortBy(column: string) {
  if (sort.value === column) order.value = order.value === 'asc' ? 'desc' : 'asc'
  else {
    sort.value = column
    order.value = 'desc'
  }
  load()
}

watch(search, () => {
  window.clearTimeout(searchTimer)
  searchTimer = window.setTimeout(() => {
    offset.value = 0
    load()
  }, 300)
})

function openCreate() {
  form.value = {
    name: '',
    data_limit_gb: 0,
    reset_strategy: 'no_reset',
    expire_in_days: 0,
    enabled: true,
    note: '',
  }
  creating.value = true
}

function openEdit(client: Client) {
  form.value = {
    name: client.name,
    data_limit_gb: client.data_limit ? client.data_limit / 1024 ** 3 : 0,
    reset_strategy: client.reset_strategy,
    expire_in_days: 0,
    enabled: client.enabled,
    note: client.note ?? '',
  }
  editing.value = client
}

async function submitForm() {
  try {
    const dataLimit = Math.round(form.value.data_limit_gb * 1024 ** 3)
    if (editing.value) {
      await api.updateClient(editing.value.name, {
        name: form.value.name,
        data_limit: dataLimit,
        reset_strategy: form.value.reset_strategy,
        enabled: form.value.enabled,
        note: form.value.note || null,
      })
      notify(`Updated ${form.value.name}`, 'success')
      editing.value = null
    } else {
      const created = await api.createClient({
        name: form.value.name,
        data_limit: dataLimit,
        reset_strategy: form.value.reset_strategy,
        expire_in_days: form.value.expire_in_days || null,
        enabled: form.value.enabled,
        note: form.value.note || null,
      })
      notify(`Created ${created.name}`, 'success')
      creating.value = false
      await openDetails(created)
    }
    await load()
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

async function openDetails(client: Client) {
  viewing.value = client
  configText.value = ''
  try {
    configText.value = await api.clientConfig(client.name)
  } catch (err) {
    configText.value = ''
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

async function toggle(client: Client) {
  try {
    if (client.enabled) await api.disableClient(client.name)
    else await api.enableClient(client.name)
    await load()
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

async function resetTraffic(client: Client) {
  if (!confirm(`Reset the traffic counter for ${client.name}?`)) return
  await api.resetClient(client.name)
  notify(`Traffic reset for ${client.name}`, 'success')
  await load()
}

async function remove(client: Client) {
  if (!confirm(`Delete ${client.name}? This cannot be undone.`)) return
  try {
    await api.deleteClient(client.name)
    notify(`Deleted ${client.name}`, 'success')
    await load()
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

function copy(text: string, label: string) {
  navigator.clipboard.writeText(text).then(
    () => notify(`${label} copied`, 'success'),
    () => notify('Clipboard is unavailable', 'error'),
  )
}

function download() {
  if (!viewing.value || !configText.value) return
  const blob = new Blob([configText.value], { type: 'text/plain' })
  const link = document.createElement('a')
  link.href = URL.createObjectURL(blob)
  link.download = `${viewing.value.name}.conf`
  link.click()
  URL.revokeObjectURL(link.href)
}

function usageRatio(client: Client) {
  return client.data_limit ? percent(client.used_total, client.data_limit) : 0
}

onMounted(() => {
  load()
  timer = window.setInterval(load, 10000)
})
onUnmounted(() => {
  window.clearInterval(timer)
  window.clearTimeout(searchTimer)
})
</script>

<template>
  <div class="page-head">
    <div>
      <h1>Clients</h1>
      <p>{{ total }} client{{ total === 1 ? '' : 's' }} on this node</p>
    </div>
    <button class="btn btn-primary" @click="openCreate">+ New client</button>
  </div>

  <div class="toolbar">
    <input v-model="search" class="search" type="text" placeholder="Search by name, note or address…" />
    <select v-model="statusFilter" style="width: auto" @change="offset = 0; load()">
      <option value="">All statuses</option>
      <option value="active">Active</option>
      <option value="disabled">Disabled</option>
      <option value="limited">Limited</option>
      <option value="expired">Expired</option>
    </select>
    <button class="btn btn-sm" :disabled="loading" @click="load">Refresh</button>
  </div>

  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th @click="sortBy('name')">Name</th>
          <th class="plain">Address</th>
          <th @click="sortBy('status')">Status</th>
          <th @click="sortBy('used_total')">Traffic</th>
          <th @click="sortBy('last_handshake_at')">Last handshake</th>
          <th @click="sortBy('expire_at')">Expires</th>
          <th class="plain"></th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="client in items" :key="client.id">
          <td>
            <div class="row" style="gap: 9px">
              <i class="dot" :class="{ on: client.is_online }" :title="client.is_online ? 'online' : 'offline'"></i>
              <div>
                <div style="font-weight: 550">{{ client.name }}</div>
                <div v-if="client.note" style="color: var(--text-dim); font-size: 12px">
                  {{ client.note }}
                </div>
              </div>
            </div>
          </td>
          <td class="mono">{{ client.address }}</td>
          <td>
            <span class="badge" :class="`badge-${client.status}`">{{ client.status }}</span>
          </td>
          <td style="min-width: 160px">
            <div style="font-size: 12.5px">
              {{ bytes(client.used_total) }}
              <span style="color: var(--text-dim)">
                / {{ client.data_limit ? bytes(client.data_limit) : '∞' }}
              </span>
            </div>
            <div v-if="client.data_limit" class="meter" style="margin-top: 6px">
              <span :style="{ width: `${usageRatio(client)}%` }"></span>
            </div>
          </td>
          <td :title="dateTime(client.last_handshake_at)">{{ relativeTime(client.last_handshake_at) }}</td>
          <td>{{ client.expire_at ? untilTime(client.expire_at) : '∞' }}</td>
          <td>
            <div class="row" style="gap: 4px; justify-content: flex-end">
              <button class="btn btn-ghost btn-sm" title="Config & QR" @click="openDetails(client)">⧉</button>
              <button class="btn btn-ghost btn-sm" title="Edit" @click="openEdit(client)">✎</button>
              <button class="btn btn-ghost btn-sm" :title="client.enabled ? 'Disable' : 'Enable'" @click="toggle(client)">
                {{ client.enabled ? '⏸' : '▶' }}
              </button>
              <button class="btn btn-ghost btn-sm" title="Reset traffic" @click="resetTraffic(client)">↺</button>
              <button class="btn btn-ghost btn-sm" title="Delete" style="color: var(--danger)" @click="remove(client)">
                ✕
              </button>
            </div>
          </td>
        </tr>
        <tr v-if="!items.length">
          <td colspan="7">
            <div class="empty">No clients yet. Create the first one to get started.</div>
          </td>
        </tr>
      </tbody>
    </table>
  </div>

  <div v-if="pages > 1" class="row" style="margin-top: 14px; justify-content: flex-end">
    <button class="btn btn-sm" :disabled="offset === 0" @click="offset -= limit; load()">Previous</button>
    <span style="color: var(--text-muted)">Page {{ page }} of {{ pages }}</span>
    <button class="btn btn-sm" :disabled="page >= pages" @click="offset += limit; load()">Next</button>
  </div>

  <ModalShell
    v-if="creating || editing"
    :title="editing ? `Edit ${editing.name}` : 'New client'"
    @close="creating = false; editing = null"
  >
    <div class="field">
      <label>Name</label>
      <input v-model="form.name" type="text" placeholder="alice-phone" />
    </div>

    <div class="two-col">
      <div class="field">
        <label>Data limit (GB)</label>
        <input v-model.number="form.data_limit_gb" type="number" min="0" step="0.5" />
        <span class="hint">0 means unlimited</span>
      </div>
      <div class="field">
        <label>Reset traffic</label>
        <select v-model="form.reset_strategy">
          <option value="no_reset">Never</option>
          <option value="day">Daily</option>
          <option value="week">Weekly</option>
          <option value="month">Monthly</option>
        </select>
      </div>
    </div>

    <div v-if="!editing" class="field">
      <label>Expires in (days)</label>
      <input v-model.number="form.expire_in_days" type="number" min="0" />
      <span class="hint">0 means the client never expires</span>
    </div>

    <div class="field">
      <label>Note</label>
      <input v-model="form.note" type="text" placeholder="Optional" />
    </div>

    <label class="switch">
      <input v-model="form.enabled" type="checkbox" />
      <span>Enabled</span>
    </label>

    <template #footer>
      <button class="btn" @click="creating = false; editing = null">Cancel</button>
      <button class="btn btn-primary" :disabled="!form.name" @click="submitForm">
        {{ editing ? 'Save' : 'Create' }}
      </button>
    </template>
  </ModalShell>

  <ModalShell v-if="viewing" wide :title="viewing.name" @close="viewing = null">
    <div class="row" style="align-items: flex-start; gap: 20px; flex-wrap: wrap">
      <img
        :src="qrUrl(viewing)"
        alt="Client QR code"
        style="width: 190px; height: 190px; border-radius: 10px; background: #fff; padding: 6px"
      />
      <dl class="kv" style="flex: 1; min-width: 260px; grid-template-columns: 120px 1fr">
        <dt>Status</dt>
        <dd><span class="badge" :class="`badge-${viewing.status}`">{{ viewing.status }}</span></dd>
        <dt>Address</dt>
        <dd class="mono">{{ viewing.address }}</dd>
        <dt>Public key</dt>
        <dd class="mono">{{ viewing.public_key }}</dd>
        <dt>Traffic</dt>
        <dd>↑ {{ bytes(viewing.used_up) }} · ↓ {{ bytes(viewing.used_down) }}</dd>
        <dt>Last handshake</dt>
        <dd>{{ dateTime(viewing.last_handshake_at) }}</dd>
        <dt>Endpoint</dt>
        <dd class="mono">{{ viewing.last_endpoint ?? '—' }}</dd>
        <dt>Subscription</dt>
        <dd class="mono">{{ viewing.subscription_url }}</dd>
      </dl>
    </div>

    <pre v-if="configText" class="config">{{ configText }}</pre>

    <template #footer>
      <button class="btn" @click="copy(viewing.subscription_url, 'Subscription link')">Copy link</button>
      <button class="btn" :disabled="!configText" @click="copy(configText, 'Config')">Copy config</button>
      <button class="btn btn-primary" :disabled="!configText" @click="download">Download .conf</button>
    </template>
  </ModalShell>
</template>
