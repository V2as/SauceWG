<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { api } from '../api'

const emit = defineEmits<{ authenticated: [] }>()
const router = useRouter()

const username = ref('')
const password = ref('')
const error = ref('')
const busy = ref(false)

async function submit() {
  error.value = ''
  busy.value = true
  try {
    await api.login(username.value, password.value)
    emit('authenticated')
    router.replace({ name: 'dashboard' })
  } catch (err) {
    error.value = err instanceof Error ? err.message : 'Login failed'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="login-page">
    <form class="login-card" @submit.prevent="submit">
      <span class="brand-mark">S</span>
      <h1>SauceWG</h1>
      <p>AmneziaWG cascade control panel</p>

      <div class="field" style="margin-bottom: 14px">
        <label for="username">Username</label>
        <input id="username" v-model="username" type="text" autocomplete="username" required />
      </div>

      <div class="field" style="margin-bottom: 18px">
        <label for="password">Password</label>
        <input
          id="password"
          v-model="password"
          type="password"
          autocomplete="current-password"
          required
        />
      </div>

      <div v-if="error" class="alert alert-error" style="margin-bottom: 14px">{{ error }}</div>

      <button class="btn btn-primary" style="width: 100%" :disabled="busy">
        {{ busy ? 'Signing in…' : 'Sign in' }}
      </button>
    </form>
  </div>
</template>
