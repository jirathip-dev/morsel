import { createMorselApp } from './app.js'

const app = createMorselApp()

export default {
  port: Number(process.env.PORT ?? '3000'),
  fetch: app.fetch,
}

