<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import {
  api,
  type BypassEntry,
  type BypassList,
  type CascadeStatus,
  type DirectRoute,
  type DirectRouteList,
} from '../api'
import ModalShell from '../components/ModalShell.vue'
import { notify } from '../store'

const state = ref<DirectRouteList | null>(null)
const bypass = ref<BypassList | null>(null)
const cascade = ref<CascadeStatus | null>(null)
const error = ref('')
const busy = ref('')
let timer: number | undefined

const adding = ref(false)
const editing = ref<DirectRoute | null>(null)
const form = ref({ cidr: '', note: '' })
const editForm = ref({ note: '' })

const addingBypass = ref(false)
const editingBypass = ref<BypassEntry | null>(null)
const bypassForm = ref({ cidr: '', v6: '', note: '' })
const bypassEditForm = ref({ v6: '', note: '' })

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

/** Every prefix in the bypass box, on the same terms as the box above. */
const parsedBypass = computed(() =>
  bypassForm.value.cidr
    .split(/[\n,;]+/)
    .map((line) => line.replace(/#.*$/, '').trim())
    .filter(Boolean),
)

const bypassSummary = computed(() => {
  const list = bypass.value
  if (!list) return ''
  if (list.mode === 'off') return 'Turned off'
  if (list.active) return 'In force now'
  return list.mode === 'always' ? 'Waiting for the relay' : 'Idle: an exit node has the traffic'
})

const bypassCooled = computed(() => bypass.value?.relay?.cooled ?? 0)

async function refresh() {
  try {
    state.value = await api.routes()
    error.value = ''
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  }
  try {
    bypass.value = await api.bypass()
  } catch {
    // The direct routes above are still worth showing without it.
    bypass.value = null
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

function openAddBypass() {
  bypassForm.value = { cidr: '', v6: '', note: '' }
  addingBypass.value = true
}

async function submitBypass() {
  busy.value = 'bypass-add'
  try {
    bypass.value = await api.addBypass({
      cidr: parsedBypass.value,
      v6: bypassForm.value.v6.trim() || null,
      note: bypassForm.value.note.trim() || null,
    })
    notify(`${parsedBypass.value.length} destination(s) will be reopened`, 'success')
    addingBypass.value = false
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

function openEditBypass(entry: BypassEntry) {
  bypassEditForm.value = { v6: entry.v6 ?? '', note: entry.note ?? '' }
  editingBypass.value = entry
}

async function saveBypassEdit() {
  if (!editingBypass.value) return
  busy.value = editingBypass.value.cidr
  try {
    bypass.value = await api.updateBypass(editingBypass.value.cidr, {
      v6: bypassEditForm.value.v6.trim() || null,
      note: bypassEditForm.value.note.trim() || null,
    })
    editingBypass.value = null
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function toggleBypass(entry: BypassEntry) {
  busy.value = entry.cidr
  try {
    bypass.value = await api.updateBypass(entry.cidr, { enabled: !entry.enabled })
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

async function removeBypass(entry: BypassEntry) {
  if (!confirm(`Stop reopening ${entry.cidr}?`)) return
  busy.value = entry.cidr
  try {
    bypass.value = await api.deleteBypass(entry.cidr)
    notify(`${entry.cidr} is no longer reopened`, 'success')
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

  <template v-if="bypass">
    <div class="page-head" style="margin-top: 28px">
      <div>
        <h1 style="font-size: 20px">Reopened destinations</h1>
        <p>
          Destinations that are blocked by dropping the connection to them, which this
          entry node opens another way
        </p>
      </div>
      <button
        class="btn btn-primary"
        :disabled="!bypass.editable || bypass.mode === 'off'"
        @click="openAddBypass"
      >
        + Reopen a destination
      </button>
    </div>

    <div v-if="bypass.config_error" class="alert alert-error" style="margin-bottom: 14px">
      {{ bypass.config_error }}
    </div>

    <div v-else-if="bypass.mode === 'off'" class="alert alert-warn" style="margin-bottom: 14px">
      This is turned off, so a destination whose IPv4 handshake is being dropped stays
      unreachable. Turn it on with <span class="mono">saucewg bypass auto</span>.
    </div>

    <div class="grid grid-4" style="margin-bottom: 14px">
      <div class="card">
        <div class="stat-label">Reopened now</div>
        <div class="stat-value">{{ bypass.relay?.prefixes ?? 0 }}</div>
        <div class="stat-sub">{{ bypassSummary }}</div>
      </div>

      <div class="card">
        <div class="stat-label">When it engages</div>
        <div class="stat-value" style="font-size: 20px">
          {{ bypass.mode === 'always' ? 'Always' : bypass.mode === 'off' ? 'Never' : 'Only via entry' }}
        </div>
        <div class="stat-sub">set with <span class="mono">saucewg bypass</span></div>
      </div>

      <div class="card">
        <div class="stat-label">Opened over IPv6</div>
        <div class="stat-value">{{ bypass.relay?.via_v6 ?? 0 }}</div>
        <div class="stat-sub">connections that took the counterpart</div>
      </div>

      <div class="card">
        <div class="stat-label">Opened by retrying</div>
        <div class="stat-value">{{ bypass.relay?.via_retry ?? 0 }}</div>
        <div class="stat-sub">
          <template v-if="bypass.relay?.via_retry">
            in {{ bypass.relay.attempts }} handshake(s){{
              bypass.relay.failed ? `, ${bypass.relay.failed} unreachable` : ''
            }}
          </template>
          <template v-else-if="bypass.relay?.failed">
            {{ bypass.relay.failed }} connection(s) could not be opened either way
          </template>
          <template v-else>no IPv4 handshake needed retrying</template>
        </div>
      </div>
    </div>

    <p v-if="bypassCooled" class="stat-sub" style="margin: -6px 0 14px">
      {{ bypassCooled }} connection(s) went to a destination that had already spent a
      whole budget without answering, so each was given one handshake instead of a
      burst. That is clients retrying something blocked outright rather than sampled:
      it costs nothing, but the destination is worth a look.
    </p>

    <div v-if="!bypass.entries.length" class="empty">
      Nothing is being reopened.
      <template v-if="bypass.groups.length">
        The built-in {{ bypass.groups.join(', ') }} table is configured, but the node
        container is not redirecting anything right now — in
        <span class="mono">auto</span> that is what an exit node carrying the traffic
        looks like.
      </template>
      <template v-else>
        Add a destination whose IPv4 connects nowhere while ping to it still answers.
      </template>
    </div>

    <div v-else class="table-wrap">
      <table style="min-width: 720px">
        <thead>
          <tr>
            <th class="plain">Destination</th>
            <th class="plain">Reached over</th>
            <th class="plain">State</th>
            <th class="plain">Label</th>
            <th class="plain"></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="entry in bypass.entries" :key="entry.cidr">
            <td class="mono" style="font-weight: 550">{{ entry.cidr }}</td>
            <td class="mono" style="font-size: 12px">
              {{ entry.v6 ?? 'its own IPv4, retried' }}
            </td>
            <td>
              <span
                class="badge"
                :class="!entry.enabled ? 'badge-disabled' : entry.active ? 'badge-active' : 'badge-limited'"
              >
                {{ !entry.enabled ? 'off' : entry.active ? 'reopened' : 'idle' }}
              </span>
              <span v-if="entry.built_in" class="badge badge-limited" style="margin-left: 4px">
                built in
              </span>
            </td>
            <td>{{ entry.note ?? '—' }}</td>
            <td>
              <div class="row" style="gap: 4px; justify-content: flex-end">
                <button
                  class="btn btn-ghost btn-sm"
                  :disabled="!bypass.editable || busy !== ''"
                  title="Edit the IPv6 counterpart or the label"
                  @click="openEditBypass(entry)"
                >
                  ✎
                </button>
                <button
                  class="btn btn-ghost btn-sm"
                  :disabled="!bypass.editable || busy !== ''"
                  :title="entry.enabled ? 'Stop reopening it, keeping it listed' : 'Reopen it again'"
                  @click="toggleBypass(entry)"
                >
                  {{ entry.enabled ? '⏸' : '▶' }}
                </button>
                <button
                  class="btn btn-ghost btn-sm"
                  style="color: var(--danger)"
                  :disabled="!bypass.editable || busy !== '' || entry.built_in"
                  :title="entry.built_in ? 'From a built-in table: turn it off instead' : 'Remove'"
                  @click="removeBypass(entry)"
                >
                  ✕
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="card" style="margin-top: 14px">
      <div class="stat-label" style="margin-bottom: 14px">When to use this instead</div>
      <p style="color: var(--text-dim); font-size: 12.5px; margin-top: 0">
        Some destinations are blocked at the moment a TCP connection is opened rather
        than by route: the SYN to their IPv4 is dropped, so nothing ever connects, while
        ping to the same address answers and existing connections keep working. No route
        change reaches those, so adding one above does nothing. This entry node opens the
        outbound half itself — over the destination's IPv6 when the same server answers
        there, and otherwise by dialling its IPv4 until one handshake gets through, which
        is enough when the filter drops most of them rather than all.
      </p>
      <p style="color: var(--text-dim); font-size: 12.5px">
        In <span class="mono">auto</span> this engages only while client traffic is
        leaving through this entry node, because a flow already going out through an exit
        node is not meeting the filter.
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

  <ModalShell v-if="addingBypass" title="Reopen a blocked destination" @close="addingBypass = false">
    <div class="field">
      <label>Addresses and ranges</label>
      <textarea
        v-model="bypassForm.cidr"
        rows="6"
        spellcheck="false"
        placeholder="203.0.113.0/24&#10;198.51.100.7"
      ></textarea>
      <span class="hint">
        One per line or comma-separated; a bare address means a single host. Anything
        after a # is ignored.
      </span>
    </div>
    <div class="field">
      <label>IPv6 counterpart <span style="color: var(--text-dim)">— optional</span></label>
      <input v-model="bypassForm.v6" type="text" placeholder="2001:db8::a" />
      <span class="hint">
        The address of the same server over IPv6, tried first. Only for a single
        destination: sending unrelated ones to one address would reach the wrong server.
        Leave it empty and the destination's own IPv4 is dialled until a handshake lands.
      </span>
    </div>
    <div class="field">
      <label>Label</label>
      <input v-model="bypassForm.note" type="text" placeholder="some service" />
    </div>

    <template #footer>
      <button class="btn" @click="addingBypass = false">Cancel</button>
      <button
        class="btn btn-primary"
        :disabled="!parsedBypass.length || busy !== ''"
        @click="submitBypass"
      >
        Reopen {{ parsedBypass.length || '' }}
      </button>
    </template>
  </ModalShell>

  <ModalShell
    v-if="editingBypass"
    :title="`Edit ${editingBypass.cidr}`"
    @close="editingBypass = null"
  >
    <div class="field">
      <label>IPv6 counterpart</label>
      <input v-model="bypassEditForm.v6" type="text" placeholder="2001:db8::a" />
      <span class="hint">Empty means the destination's own IPv4 is retried instead.</span>
    </div>
    <div class="field">
      <label>Label</label>
      <input v-model="bypassEditForm.note" type="text" placeholder="some service" />
    </div>

    <template #footer>
      <button class="btn" @click="editingBypass = null">Cancel</button>
      <button class="btn btn-primary" :disabled="busy !== ''" @click="saveBypassEdit">Save</button>
    </template>
  </ModalShell>
</template>
