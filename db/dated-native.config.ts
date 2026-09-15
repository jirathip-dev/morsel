import { defineConfig } from 'vitest/config'

// Optional live evidence driver, not a replacement for either canonical gate.
export default defineConfig({
  test: { include: ['db/dated-native.evidence.ts'], testTimeout: 1_800_000 },
})
