<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { api, auth } from './api'
import { setAdmin, store } from './store'

const route = useRoute()
const router = useRouter()
const version = ref('')

const isLogin = computed(() => route.name === 'login')

function onUnauthorized() {
  setAdmin(null)
  router.replace({ name: 'login' })
}

async function loadIdentity() {
  if (!auth.token) return
  try {
    setAdmin(await api.me())
    version.value = (await api.system()).version
  } catch {
    onUnauthorized()
  }
}

function logout() {
  auth.token = null
  setAdmin(null)
  router.replace({ name: 'login' })
}

onMounted(() => {
  window.addEventListener('saucewg:unauthorized', onUnauthorized)
  loadIdentity()
})
onUnmounted(() => window.removeEventListener('saucewg:unauthorized', onUnauthorized))
</script>

<template>
  <div v-if="isLogin">
    <RouterView @authenticated="loadIdentity" />
  </div>

  <div v-else class="shell">
    <aside class="sidebar">
      <div class="brand">
        <span class="brand-mark">S</span>
        <span>SauceWG</span>
      </div>

      <nav class="nav">
        <RouterLink to="/">Dashboard</RouterLink>
        <RouterLink to="/clients">Clients</RouterLink>
        <RouterLink to="/settings">Node</RouterLink>
        <RouterLink v-if="store.admin?.is_sudo" to="/admins">Admins</RouterLink>
      </nav>

      <div class="sidebar-footer">
        <div class="row-between">
          <span>{{ store.admin?.username ?? '—' }}</span>
          <button class="btn btn-ghost btn-sm" @click="logout">Sign out</button>
        </div>
        <span v-if="version">v{{ version }}</span>
      </div>
    </aside>

    <main class="main">
      <RouterView />
    </main>
  </div>

  <div class="toast-stack">
    <div v-for="toast in store.toasts" :key="toast.id" class="toast" :class="toast.kind">
      {{ toast.message }}
    </div>
  </div>
</template>
