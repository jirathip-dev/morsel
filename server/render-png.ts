// Rasterizes the dashboard SVG (server/render.ts) to PNG for MCP image
// content (issue #158). resvg-js is a native N-API module, so it is imported
// DYNAMICALLY at call time, never at module scope: server/tools.ts is shared
// with the Supabase Edge Function (Deno), whose runtime cannot load N-API
// addons and whose bundler resolves npm specifiers through the root
// deno.json import map. Callers catch the unavailable-module failure and
// fall back to the SVG image block, so every origin still returns a visual.

export const DASHBOARD_PNG_WIDTH = 1440 // 2x the 720-wide SVG viewBox (retina-crisp chat image)

export async function rasterizeDashboardSvg(svg: string): Promise<Uint8Array> {
  const { Resvg } = await import('@resvg/resvg-js')
  const resvg = new Resvg(svg, { fitTo: { mode: 'width', value: DASHBOARD_PNG_WIDTH } })
  return Uint8Array.from(resvg.render().asPng())
}
