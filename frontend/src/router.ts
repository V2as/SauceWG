import { createRouter, createWebHistory } from 'vue-router'
import { auth } from './api'

const routes = [
  { path: '/login', name: 'login', component: () => import('./views/LoginView.vue') },
  { path: '/', name: 'dashboard', component: () => import('./views/DashboardView.vue') },
  { path: '/clients', name: 'clients', component: () => import('./views/ClientsView.vue') },
  { path: '/exit-nodes', name: 'exit-nodes', component: () => import('./views/ExitNodesView.vue') },
  { path: '/routing', name: 'routing', component: () => import('./views/RoutingView.vue') },
  { path: '/torrents', name: 'torrents', component: () => import('./views/TorrentsView.vue') },
  { path: '/admins', name: 'admins', component: () => import('./views/AdminsView.vue') },
  { path: '/settings', name: 'settings', component: () => import('./views/SettingsView.vue') },
  { path: '/:pathMatch(.*)*', redirect: '/' },
]

export const router = createRouter({
  history: createWebHistory(),
  routes,
})

router.beforeEach((to) => {
  if (to.name !== 'login' && !auth.token) return { name: 'login' }
  if (to.name === 'login' && auth.token) return { name: 'dashboard' }
  return true
})
