<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api, type CascadeStatus, type DirectRoute, type DirectRouteList } from '../api'
import ModalShell from '../components/ModalShell.vue'
import { notify } from '../store'

const state = ref<DirectRouteList | null>(null)
const cascade = ref<CascadeStatus | null>(null)
const error = ref('')
const busy = ref('')
let timer: number | undefined

const adding = ref(false)
const editing = ref<DirectRoute | null>(null)
const form = ref({ cidr: '', note: '' })
const editForm = ref({ note: '' })

const groups = computed(() => {
  const seen = new Map<string, number>()
  for (const route of state.value?.routes ?? []) {
    const key = route.note?.trim() || ''
    if (key) seen.set(key, (seen.get(key) ?? 0) + 1)
  }
  return [...seen.entries()].sort((a, b) => b[1] - a[1])
})

/** Every prefix in the box, one per line or comma-separated, ignoring comments. */
const parsed = computed(() =>
  form.value.cidr
    .split(/[\n,;]+/)
    .map((line) => line.replace(/#.*$/, '').trim())
    .filter(Boolean),
)

async function refresh() {
  try {
    state.value = await api.routes()
    error.value = ''
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  }
}

async function loadCascade() {
  try {
    cascade.value = (await api.system()).cascade
  } catch {
    // The routing list is still worth showing without it.
    cascade.value = null
  }
}

function openAdd() {
  form.value = { cidr: '', note: '' }
  adding.value = true
}

async function submit() {
  busy.value = 'add'
  try {
    state.value = await api.addRoutes({
      cidr: parsed.value,
      note: form.value.note.trim() || null,
    })
    notify(`${parsed.value.length} destination(s) now bypass the cascade`, 'success')
    adding.value = false
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

function openEdit(route: DirectRoute) {
  editForm.value = { note: route.note ?? '' }
  editing.value = route
}

async function saveEdit() {
  if (!editing.value) return
  busy.value = editing.value.cidr
  try {
    state.value = await api.updateRoute(editing.value.cidr, {
      note: editForm.value.note.trim() || null,
    })
    editing.value = null
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function toggle(route: DirectRoute) {
  busy.value = route.cidr
  try {
    state.value = await api.updateRoute(route.cidr, { enabled: !route.enabled })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function remove(route: DirectRoute) {
  if (!confirm(`Put ${route.cidr} back on the cascade?`)) return
  busy.value = route.cidr
  try {
    state.value = await api.deleteRoute(route.cidr)
    notify(`${route.cidr} goes through the exit node again`, 'success')
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function removeGroup(note: string) {
  const members = (state.value?.routes ?? []).filter((r) => (r.note?.trim() || '') === note)
  if (!confirm(`Put all ${members.length} destinations labelled "${note}" back on the cascade?`)) return
  busy.value = note
  try {
    for (const route of members) state.value = await api.deleteRoute(route.cidr)
    notify(`Removed ${members.length} route(s)`, 'success')
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

onMounted(() => {
  refresh()
  loadCascade()
  timer = window.setInterval(() => {
    refresh()
    loadCascade()
  }, 10000)
})
onUnmounted(() => window.clearInterval(timer))
</script>

<template>
  <div class="page-head">
    <div>
      <h1>Routing</h1>
      <p>Destinations that skip the cascade and leave through this entry node</p>
    </div>
    <button class="btn btn-primary" :disabled="!state?.editable" @click="openAdd">
      + Add destination
    </button>
  </div>

  <div v-if="error" class="alert alert-error" style="margin-bottom: 14px">{{ error }}</div>

  <template v-if="state">
    <div v-if="state.config_error" class="alert alert-error" style="margin-bottom: 14px">
      {{ state.config_error }}
    </div>

    <div v-else-if="state.routes.length && !state.live" class="alert alert-warn" style="margin-bottom: 14px">
      The node container is not reporting its routing state, so nothing below is
      confirmed to be in effect. It may be stopped, or older than this feature.
    </div>

    <div class="grid grid-4" style="margin-bottom: 14px">
      <div class="card">
        <div class="stat-label">Direct destinations</div>
        <div class="stat-value">{{ state.routes.filter((r) => r.active).length }}</div>
        <div class="stat-sub">
          of {{ state.routes.length }} listed<span v-if="state.via">, via {{ state.via }}</span>
        </div>
      </div>

      <div class="card">
        <div class="stat-label">Everything else</div>
        <div class="stat-value" style="font-size: 20px">
          {{ cascade?.node ?? (cascade?.fallback_active ? 'this entry node' : '—') }}
        </div>
        <div class="stat-sub">
          {{ cascade?.node ? 'through the cascade' : 'no exit node is carrying traffic' }}
        </div>
      </div>

      <div class="card">
        <div class="stat-label">If every node fails</div>
        <div class="stat-value" style="font-size: 20px">
          {{ cascade?.fallback === 'block' ? 'Blocked' : 'Via entry node' }}
        </div>
        <div class="stat-sub">
          set with <span class="mono">saucewg fallback</span>
        </div>
      </div>

      <div class="card">
        <div class="stat-label">Groups</div>
        <div class="stat-value">{{ groups.length }}</div>
        <div class="stat-sub">labels used to remove several at once</div>
      </div>
    </div>

    <div v-if="!state.routes.length" class="empty">
      Nothing bypasses the cascade: every destination goes through the active exit node.
      Add a range to send it out of this entry node instead — for a service that has to
      see a local address, or one you would rather not send abroad.
    </div>

    <template v-else>
      <div v-if="groups.length" class="row" style="gap: 6px; margin-bottom: 14px; flex-wrap: wrap">
        <span
          v-for="[name, count] in groups"
          :key="name"
          class="badge badge-active"
          style="gap: 6px; display: inline-flex; align-items: center"
        >
          {{ name }} · {{ count }}
          <button
            v-if="state.editable"
            class="btn btn-ghost btn-sm"
            style="padding: 0 4px; min-height: 0"
            :disabled="busy !== ''"
            :title="`Remove every route labelled ${name}`"
            @click="removeGroup(name)"
          >
            ✕
          </button>
        </span>
      </div>

      <div class="table-wrap">
        <table style="min-width: 640px">
          <thead>
            <tr>
              <th class="plain">Destination</th>
              <th class="plain">State</th>
              <th class="plain">Label</th>
              <th class="plain"></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="route in state.routes" :key="route.cidr">
              <td class="mono" style="font-weight: 550">{{ route.cidr }}</td>
              <td>
                <span
                  class="badge"
                  :class="!route.enabled ? 'badge-disabled' : route.active ? 'badge-active' : 'badge-limited'"
                >
                  {{ !route.enabled ? 'off' : route.active ? 'direct' : 'pending' }}
                </span>
              </td>
              <td>{{ route.note ?? '—' }}</td>
              <td>
                <div class="row" style="gap: 4px; justify-content: flex-end">
                  <button
                    class="btn btn-ghost btn-sm"
                    :disabled="!state.editable || busy !== ''"
                    title="Edit label"
                    @click="openEdit(route)"
                  >
                    ✎
                  </button>
                  <button
                    class="btn btn-ghost btn-sm"
                    :disabled="!state.editable || busy !== ''"
                    :title="route.enabled ? 'Put back on the cascade, keeping it listed' : 'Route it directly again'"
                    @click="toggle(route)"
                  >
                    {{ route.enabled ? '⏸' : '▶' }}
                  </button>
                  <button
                    class="btn btn-ghost btn-sm"
                    style="color: var(--danger)"
                    :disabled="!state.editable || busy !== ''"
                    title="Remove"
                    @click="remove(route)"
                  >
                    ✕
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>

    <div class="card" style="margin-top: 14px">
      <div class="stat-label" style="margin-bottom: 14px">How this works</div>
      <p style="color: var(--text-dim); font-size: 12.5px; margin-top: 0">
        Listed destinations are looked up in their own routing table, which is consulted
        before the cascade — so they leave through this server's own address while
        everything else still goes to an exit node. Only IPv4 addresses and ranges;
        names are not resolved, so add the ranges a service actually uses. Changes apply
        within a second, without disturbing any tunnel.
      </p>
    </div>
  </template>

  <ModalShell v-if="adding" title="Send destinations through the entry node" @close="adding = false">
    <div class="field">
      <label>Addresses and ranges</label>
      <textarea
        v-model="form.cidr"
        rows="7"
        spellcheck="false"
        placeholder="142.250.0.0/15&#10;64.233.160.0/19&#10;8.8.8.8"
      ></textarea>
      <span class="hint">
        One per line or comma-separated; a bare address means a single host. Anything
        after a # is ignored, so a generated list can be pasted as it is.
      </span>
    </div>
    <div class="field">
      <label>Label</label>
      <input v-model="form.note" type="text" placeholder="youtube" />
      <span class="hint">Groups them so they can be removed together later.</span>
    </div>

    <template #footer>
      <button class="btn" @click="adding = false">Cancel</button>
      <button class="btn btn-primary" :disabled="!parsed.length || busy !== ''" @click="submit">
        Add {{ parsed.length || '' }}
      </button>
    </template>
  </ModalShell>

  <ModalShell v-if="editing" :title="`Edit ${editing.cidr}`" @close="editing = null">
    <div class="field">
      <label>Label</label>
      <input v-model="editForm.note" type="text" placeholder="youtube" />
    </div>

    <template #footer>
      <button class="btn" @click="editing = null">Cancel</button>
      <button class="btn btn-primary" :disabled="busy !== ''" @click="saveEdit">Save</button>
    </template>
  </ModalShell>
</template>
