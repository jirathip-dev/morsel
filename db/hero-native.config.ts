import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: { include: ['db/hero-native.evidence.ts'], testTimeout: 1_200_000 },
})
