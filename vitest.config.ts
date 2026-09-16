import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // #277: drain recovery-worker IPC between synchronous PostgreSQL cases.
    // Keep every suite in quality and retain Vitest's RPC/test timeout budgets.
    setupFiles: ['./db/vitest-worker-setup.ts'],
  },
})
