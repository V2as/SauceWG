<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { api, type Admin } from '../api'
import ModalShell from '../components/ModalShell.vue'
import { notify, store } from '../store'
import { dateTime, relativeTime } from '../utils/format'

const admins = ref<Admin[]>([])
const creating = ref(false)
const editing = ref<Admin | null>(null)
const form = ref({ username: '', password: '', is_sudo: false })

async function load() {
  try {
    admins.value = await api.admins()
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

function openCreate() {
  form.value = { username: '', password: '', is_sudo: false }
  creating.value = true
}

function openEdit(admin: Admin) {
  form.value = { username: admin.username, password: '', is_sudo: admin.is_sudo }
  editing.value = admin
}

async function submit() {
  try {
    if (editing.value) {
      const payload: Record<string, unknown> = { is_sudo: form.value.is_sudo }
      if (form.value.password) payload.password = form.value.password
      await api.updateAdmin(editing.value.username, payload)
      notify(`Updated ${editing.value.username}`, 'success')
      editing.value = null
    } else {
      await api.createAdmin(form.value)
      notify(`Created ${form.value.username}`, 'success')
      creating.value = false
    }
    await load()
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

async function toggleActive(admin: Admin) {
  try {
    await api.updateAdmin(admin.username, { is_active: !admin.is_active })
    await load()
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

async function remove(admin: Admin) {
  if (!confirm(`Delete admin ${admin.username}?`)) return
  try {
    await api.deleteAdmin(admin.username)
    notify(`Deleted ${admin.username}`, 'success')
    await load()
  } catch (err) {
    notify(err instanceof Error ? err.message : String(err), 'error')
  }
}

onMounted(load)
</script>

<template>
  <div class="page-head">
    <div>
      <h1>Admins</h1>
      <p>Accounts that can sign in to the panel and the API</p>
    </div>
    <button class="btn btn-primary" @click="openCreate">+ New admin</button>
  </div>

  <div class="table-wrap">
    <table style="min-width: 640px">
      <thead>
        <tr>
          <th class="plain">Username</th>
          <th class="plain">Role</th>
          <th class="plain">State</th>
          <th class="plain">Last login</th>
          <th class="plain">Created</th>
          <th class="plain"></th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="admin in admins" :key="admin.id">
          <td style="font-weight: 550">{{ admin.username }}</td>
          <td>
            <span class="badge" :class="admin.is_sudo ? 'badge-active' : 'badge-disabled'">
              {{ admin.is_sudo ? 'sudo' : 'standard' }}
            </span>
          </td>
          <td>
            <span class="badge" :class="admin.is_active ? 'badge-active' : 'badge-expired'">
              {{ admin.is_active ? 'active' : 'disabled' }}
            </span>
          </td>
          <td :title="dateTime(admin.last_login_at)">{{ relativeTime(admin.last_login_at) }}</td>
          <td>{{ dateTime(admin.created_at) }}</td>
          <td>
            <div class="row" style="gap: 4px; justify-content: flex-end">
              <button class="btn btn-ghost btn-sm" title="Edit" @click="openEdit(admin)">✎</button>
              <button
                class="btn btn-ghost btn-sm"
                :disabled="admin.id === store.admin?.id"
                :title="admin.is_active ? 'Disable' : 'Enable'"
                @click="toggleActive(admin)"
              >
                {{ admin.is_active ? '⏸' : '▶' }}
              </button>
              <button
                class="btn btn-ghost btn-sm"
                style="color: var(--danger)"
                :disabled="admin.id === store.admin?.id"
                title="Delete"
                @click="remove(admin)"
              >
                ✕
              </button>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
  </div>

  <ModalShell
    v-if="creating || editing"
    :title="editing ? `Edit ${editing.username}` : 'New admin'"
    @close="creating = false; editing = null"
  >
    <div class="field">
      <label>Username</label>
      <input v-model="form.username" type="text" :disabled="!!editing" />
    </div>
    <div class="field">
      <label>Password</label>
      <input v-model="form.password" type="password" :placeholder="editing ? 'Leave blank to keep' : ''" />
      <span class="hint">At least 6 characters</span>
    </div>
    <label class="switch">
      <input v-model="form.is_sudo" type="checkbox" />
      <span>Sudo access</span>
    </label>

    <template #footer>
      <button class="btn" @click="creating = false; editing = null">Cancel</button>
      <button
        class="btn btn-primary"
        :disabled="!form.username || (!editing && form.password.length < 6)"
        @click="submit"
      >
        {{ editing ? 'Save' : 'Create' }}
      </button>
    </template>
  </ModalShell>
</template>
