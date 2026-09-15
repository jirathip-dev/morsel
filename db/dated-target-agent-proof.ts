import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import { expect } from 'vitest'
import { createMorselApp } from '../server/app.ts'
import { SetDatedTargetAdditionOutputSchema } from '../packages/schema/food-types.ts'
import type { MorselRepository } from '../server/repository.ts'

/** The real MCP registration/HTTP entry point, backed by the caller's SQL repository. */
export async function verifyDatedAgentWrite(repository: MorselRepository, userId: string): Promise<void> {
  const app = createMorselApp({
    authenticate: (token) => Promise.resolve({
      userId, email: 'dated@example.invalid', token,
      authInfo: { token, clientId: 'dated-local-agent', scopes: [], extra: { userId } },
    }),
    repositoryFactory: () => repository,
    enableJsonResponse: true,
  })
  const client = new Client({ name: 'dated-local-agent', version: '1' })
  const transport = new StreamableHTTPClientTransport(new URL('https://local-agent.test/mcp'), {
    fetch: (url, init) => Promise.resolve(app.fetch(new Request(url.toString(), init))),
    requestInit: { headers: { Authorization: 'Bearer local-fixture' } },
  })
  try {
    await client.connect(transport)
    const result = await client.callTool({ name: 'set_dated_target_addition', arguments: {
      date: '2026-03-10', timezone: 'America/New_York', addition_kcal: 200,
      expected_revision: '00000000-0000-4000-8000-000000002537',
      mutation_id: '00000000-0000-4000-8000-000000002538',
      historical_confirmation: false, manual_goal_acknowledged: false,
    } })
    expect(result.isError).not.toBe(true)
    expect(SetDatedTargetAdditionOutputSchema.parse(result.structuredContent).dated_target.addition_revision?.revision_id)
      .toBe('00000000-0000-4000-8000-000000002538')
    console.log('DATED-MCP: authenticated tools/call persisted addition revision through the real SQL repository')
  } finally {
    await client.close()
  }
}
