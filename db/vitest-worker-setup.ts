import { setImmediate } from 'node:timers/promises'
import { afterEach, expect } from 'vitest'

if (expect.getState().testPath?.endsWith('/db/migration-recovery-integration.test.mjs')) {
  // #277: these async cases use spawnSync-backed queries. Resolved promises
  // drain microtasks, not IPC: for measured onTaskUpdate requests the parent
  // replied immediately, but replies waited in this worker across cases
  // past Vitest's 60s RPC deadline. Yield to I/O after each case, not just at
  // file teardown. Isolation into another job alone cannot fix self-starvation.
  // Two turns guarantee a poll phase even if the first resumes in check.
  afterEach(async () => {
    await setImmediate()
    await setImmediate()
  })
}
