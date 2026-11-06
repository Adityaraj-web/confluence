import react from '@vitejs/plugin-react'
import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'

const root = fileURLToPath(new URL('..', import.meta.url))

/** One KEY from the root .env, falling back to .env.example (Vite's loadEnv cannot fall back between files). */
function envKey(name: string): string {
  for (const file of ['.env', '.env.example']) {
    const path = `${root}${file}`
    if (!existsSync(path)) continue
    const m = readFileSync(path, 'utf8').match(new RegExp(`^\\s*${name}\\s*=\\s*(.*?)\\s*$`, 'm'))
    if (m && m[1]) return m[1].replace(/^["']|["']$/g, '')
  }
  return ''
}

/** Dev only: serves deployments/local.json at /__local/deployment.json. A static build has no such route (replay mode). */
function localDeployment(): Plugin {
  return {
    name: 'confluence-local-deployment',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use('/__local/deployment.json', (_req, res) => {
        res.setHeader('cache-control', 'no-store')
        try {
          const body = readFileSync(`${root}deployments/local.json`)
          res.setHeader('content-type', 'application/json')
          res.end(body)
        } catch {
          res.statusCode = 404
          res.end(JSON.stringify({ error: 'deployments/local.json not found: run `pnpm --dir scripts run deploy`' }))
        }
      })
    },
  }
}

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), localDeployment()],
  // anvil's public test key #2 (the trader). Public by design (D-24, D-25); live.ts uses it only after the anvil check.
  define: { __TRADER_KEY__: JSON.stringify(envKey('TRADER_PRIVATE_KEY')) },
  // The engine imports the generated ABIs from ../scripts/src/abis, outside the web root.
  server: { fs: { allow: ['..'] } },
})
