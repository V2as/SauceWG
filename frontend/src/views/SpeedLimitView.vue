<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api, type SpeedLimitStatus } from '../api'
import { notify } from '../store'

const state = ref<SpeedLimitStatus | null>(null)
const error = ref('')
const busy = ref('')
// What is in the box, kept apart from what is on file so that the periodic
// refresh does not overwrite a number halfway through being typed.
const draft = ref<number | string>('')
const edited = ref(false)
let timer: number | undefined

const MIN_MBIT = 0.1
const MAX_MBIT = 10000
const PRESETS = [10, 20, 50, 100, 200]

const rate = computed(() => (typeof draft.value === 'number' ? draft.value : Number.NaN))
const valid = computed(
  () => Number.isFinite(rate.value) && rate.value >= MIN_MBIT && rate.value <= MAX_MBIT,
)

/** Megabytes a second, which is what a browser's download bar shows. */
function megabytes(mbit: number): string {
  const mb = mbit / 8
  return `${Number(mb.toFixed(mb < 1 ? 4 : 2))} MB/s`
}

/** The rate a client is actually held to right now, or null when there is none. */
const inForce = computed(() => (state.value?.active ? state.value.active_rate_mbit : null))

/** The rate the switch above asks for, whether or not the node has applied it yet. */
const asked = computed(() =>
  state.value?.enabled && state.value.rate_mbit !== null ? state.value.rate_mbit : null,
)

const headline = computed(() => {
  if (inForce.value !== null) return `${inForce.value} Mbit/s`
  if (asked.value !== null) return `${asked.value} Mbit/s`
  return 'Unlimited'
})

const headlineSub = computed(() => {
  if (inForce.value !== null) return `${megabytes(inForce.value)} down, and the same up`
  if (asked.value !== null) return `${megabytes(asked.value)} once it is in force`
  const kept = state.value?.rate_mbit
  return kept != null ? `${kept} Mbit/s kept on file for when it is on` : 'no rate chosen yet'
})

const status = computed(() => {
  const current = state.value
  if (!current) return ''
  if (!current.live) return 'Unknown'
  if (current.active) return 'In force'
  if (!current.enabled) return 'Off'
  return current.config_error ? 'Not in force' : 'Pending'
})

/** What the node is doing right now, in the words the switch above is set in. */
const summary = computed(() => {
  const current = state.value
  if (!current) return ''
  if (!current.live) return 'The node container is not reporting'
  if (current.active) return `on the client interface, with ${current.rules} rule(s)`
  if (!current.enabled) return 'Clients are not limited'
  return current.config_error
    ? 'The node could not apply it; see above'
    : 'Turned on, waiting for the node to apply it'
})

const unchanged = computed(
  () => state.value?.enabled === true && valid.value && rate.value === state.value.rate_mbit,
)

async function refresh() {
  try {
    state.value = await api.speedLimit()
    if (!edited.value) draft.value = state.value.rate_mbit ?? ''
    error.value = ''
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err)
  }
}

function pick(preset: number) {
  draft.value = preset
  edited.value = true
}

async function toggle() {
  if (!state.value) return
  const next = !state.value.enabled
  const payload: { enabled: boolean; rate_mbit?: number } = { enabled: next }
  // Turning it on needs a rate, and the one in the box is the obvious one to use
  // when nothing is on file yet.
  if (next && state.value.rate_mbit === null) {
    if (!valid.value) {
      notify(`Choose a rate between ${MIN_MBIT} and ${MAX_MBIT} Mbit/s first`, 'error')
      return
    }
    payload.rate_mbit = rate.value
  }
  busy.value = 'enabled'
  try {
    state.value = await api.setSpeedLimit(payload)
    edited.value = false
    draft.value = state.value.rate_mbit ?? ''
    notify(
      next
        ? `Every client is now limited to ${state.value.rate_mbit} Mbit/s each way`
        : 'Clients are no longer limited',
      'success',
    )
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  } finally {
    busy.value = ''
  }
}

// Applying a rate also turns the limit on: typing a number and pressing the button
// next to it is asking for that number to be the limit.
async function apply() {
  if (!state.value || !valid.value || unchanged.value) return
  busy.value = 'rate'
  try {
    state.value = await api.setSpeedLimit({ enabled: true, rate_mbit: rate.value })
    edited.value = false
    draft.value = state.value.rate_mbit ?? ''
    notify(`Every client is now limited to ${state.value.rate_mbit} Mbit/s each way`, 'success')
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
      <h1>Speed limit</h1>
      <p>The most any one client can move through this node, each way</p>
    </div>
    <label v-if="state" class="switch">
      <input
        type="checkbox"
        :checked="state.enabled"
        :disabled="!state.editable || busy !== ''"
        @change="toggle"
      />
      <span>{{ state.enabled ? 'Limited' : 'Off' }}</span>
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

    <div class="grid grid-4" style="margin-bottom: 14px">
      <div class="card">
        <div class="stat-label">Per client</div>
        <div class="stat-value">{{ headline }}</div>
        <div class="stat-sub">{{ headlineSub }}</div>
      </div>

      <div class="card">
        <div class="stat-label">Status</div>
        <div class="stat-value" style="font-size: 20px">{{ status }}</div>
        <div class="stat-sub">{{ summary }}</div>
      </div>

      <div class="card">
        <div class="stat-label">Dropped from clients</div>
        <div class="stat-value">{{ state.dropped.up.toLocaleString() }}</div>
        <div class="stat-sub">packets over the limit on the way up</div>
      </div>

      <div class="card">
        <div class="stat-label">Dropped to clients</div>
        <div class="stat-value">{{ state.dropped.down.toLocaleString() }}</div>
        <div class="stat-sub">packets over the limit on the way down</div>
      </div>
    </div>

    <div class="card" style="margin-bottom: 14px">
      <div class="row-between" style="margin-bottom: 14px; flex-wrap: wrap">
        <div class="stat-label" style="margin: 0">Maximum speed for each client</div>
        <div class="row" style="gap: 6px">
          <button
            v-for="preset in PRESETS"
            :key="preset"
            class="btn btn-sm"
            :class="rate === preset ? 'btn-primary' : ''"
            :disabled="!state.editable || busy !== ''"
            @click="pick(preset)"
          >
            {{ preset }}
          </button>
        </div>
      </div>

      <div class="row" style="flex-wrap: wrap">
        <div style="width: 160px">
          <input
            v-model.number="draft"
            type="number"
            :min="MIN_MBIT"
            :max="MAX_MBIT"
            step="any"
            placeholder="50"
            :disabled="!state.editable || busy !== ''"
            @input="edited = true"
            @keyup.enter="apply"
          />
        </div>
        <span style="color: var(--text-muted)">Mbit/s</span>
        <button
          class="btn btn-primary"
          :disabled="!state.editable || busy !== '' || !valid || unchanged"
          @click="apply"
        >
          {{ state.enabled ? 'Apply' : 'Limit every client to this' }}
        </button>
      </div>
      <div class="stat-sub" style="margin-top: 8px">
        {{
          valid
            ? `That is ${megabytes(rate)} for each client to download, and the same again to upload.`
            : `A rate from ${MIN_MBIT} to ${MAX_MBIT} Mbit/s. Divide by eight for MB/s.`
        }}
      </div>
    </div>

    <div class="card">
      <div class="stat-label" style="margin-bottom: 14px">How the limit works</div>
      <p style="color: var(--text-dim); font-size: 12.5px; margin-top: 0">
        <strong style="color: var(--text)">One number, applied to every client on its own.</strong>
        At 50 Mbit/s each client can download at up to 50 and upload at up to 50,
        however many of the others are doing the same — it is not a total shared
        between them. A client created after the limit was set is held to it from its
        first packet, and nothing about it appears in a client's profile.
      </p>
      <p style="color: var(--text-dim); font-size: 12.5px">
        <strong style="color: var(--text)">Over the limit is dropped, not queued.</strong>
        A download slows to the limit the way it would on a congested line. A client
        that has been idle gets its first second at full speed, so a short speed test
        can read a little above the number; anything longer averages out to it.
      </p>
      <p style="color: var(--text-dim); font-size: 12.5px; margin-bottom: 0">
        Changes apply within a second, without disturbing any tunnel: clients at the
        limit stay connected, because the tunnel's own handshakes are never counted
        against it.
      </p>
    </div>
  </template>
</template>
