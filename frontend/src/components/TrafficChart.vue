<script setup lang="ts">
import { computed } from 'vue'
import { bytes } from '../utils/format'

const props = defineProps<{
  points: { bucket: string; up: number; down: number }[]
  height?: number
}>()

const H = computed(() => props.height ?? 160)
const W = 600

const series = computed(() => {
  const points = props.points
  if (points.length === 0) return null

  const max = Math.max(...points.map((p) => p.up + p.down), 1)
  const step = points.length > 1 ? W / (points.length - 1) : W

  const build = (pick: (p: (typeof points)[number]) => number) =>
    points
      .map((p, i) => `${(i * step).toFixed(1)},${(H.value - (pick(p) / max) * (H.value - 8)).toFixed(1)}`)
      .join(' ')

  const down = build((p) => p.down)
  const total = build((p) => p.up + p.down)

  return {
    max,
    downLine: down,
    totalLine: total,
    downArea: `0,${H.value} ${down} ${W},${H.value}`,
    totalArea: `0,${H.value} ${total} ${W},${H.value}`,
  }
})
</script>

<template>
  <div>
    <svg v-if="series" :viewBox="`0 0 ${W} ${H}`" preserveAspectRatio="none" :style="{ width: '100%', height: `${H}px` }">
      <defs>
        <linearGradient id="fill-total" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.35" />
          <stop offset="100%" stop-color="#38bdf8" stop-opacity="0" />
        </linearGradient>
        <linearGradient id="fill-down" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stop-color="#10b981" stop-opacity="0.4" />
          <stop offset="100%" stop-color="#10b981" stop-opacity="0" />
        </linearGradient>
      </defs>

      <polygon :points="series.totalArea" fill="url(#fill-total)" />
      <polyline :points="series.totalLine" fill="none" stroke="#38bdf8" stroke-width="1.6" />
      <polygon :points="series.downArea" fill="url(#fill-down)" />
      <polyline :points="series.downLine" fill="none" stroke="#10b981" stroke-width="1.6" />
    </svg>

    <div v-else class="empty" :style="{ height: `${H}px`, display: 'grid', placeItems: 'center' }">
      No traffic recorded yet
    </div>

    <div v-if="series" class="row" style="margin-top: 10px; font-size: 12px; color: var(--text-dim)">
      <span class="row" style="gap: 6px">
        <i class="dot" style="background: #10b981"></i> Download
      </span>
      <span class="row" style="gap: 6px">
        <i class="dot" style="background: #38bdf8"></i> Total
      </span>
      <span style="margin-left: auto">peak {{ bytes(series.max) }} / bucket</span>
    </div>
  </div>
</template>
