const UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB']

export function bytes(value: number, digits = 2): string {
  if (!value || value < 0) return '0 B'
  const index = Math.min(Math.floor(Math.log(value) / Math.log(1024)), UNITS.length - 1)
  const scaled = value / 1024 ** index
  return `${scaled.toFixed(index === 0 ? 0 : digits)} ${UNITS[index]}`
}

export function speed(value: number): string {
  return `${bytes(value, 1)}/s`
}

export function percent(used: number, total: number): number {
  if (!total) return 0
  return Math.min(100, Math.round((used / total) * 100))
}

export function duration(seconds: number): string {
  const days = Math.floor(seconds / 86400)
  const hours = Math.floor((seconds % 86400) / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  if (days) return `${days}d ${hours}h`
  if (hours) return `${hours}h ${minutes}m`
  return `${minutes}m`
}

export function relativeTime(value: string | null): string {
  if (!value) return 'never'
  const delta = (Date.now() - new Date(value).getTime()) / 1000
  if (delta < 0) return 'just now'
  if (delta < 60) return `${Math.floor(delta)}s ago`
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`
  if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`
  return `${Math.floor(delta / 86400)}d ago`
}

export function untilTime(value: string | null): string {
  if (!value) return 'never'
  const delta = (new Date(value).getTime() - Date.now()) / 1000
  if (delta <= 0) return 'expired'
  if (delta < 3600) return `in ${Math.floor(delta / 60)}m`
  if (delta < 86400) return `in ${Math.floor(delta / 3600)}h`
  return `in ${Math.floor(delta / 86400)}d`
}

export function dateTime(value: string | null): string {
  if (!value) return '—'
  return new Date(value).toLocaleString()
}

export function parseSize(input: string): number {
  const match = input.trim().match(/^([\d.]+)\s*(B|KB|MB|GB|TB)?$/i)
  if (!match) return 0
  const scale: Record<string, number> = { B: 1, KB: 1024, MB: 1024 ** 2, GB: 1024 ** 3, TB: 1024 ** 4 }
  return Math.round(parseFloat(match[1]) * (scale[(match[2] ?? 'GB').toUpperCase()] ?? 1))
}
