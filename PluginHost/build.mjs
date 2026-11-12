// Builds the plugin host into dist/: index.html + assets/host.js (one classic IIFE script) +
// assets/host.css + fonts. Relative URLs only, no module scripts, so it loads from file:// in a
// WKWebView.
//
// The toolchain (vite, tailwind, react plugin) and every runtime dependency are borrowed from the
// Hermes Desktop checkout (HERMES_DESKTOP_DIR, read-only): nothing is written there.
//
//   node build.mjs              # production build -> dist/
//   HERMES_DESKTOP_DIR=... node build.mjs

import fs from 'node:fs'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const desktopDir = path.resolve(process.env.HERMES_DESKTOP_DIR || path.join(os.homedir(), '.hermes/hermes-agent/apps/desktop'))
const pluginsDir = path.resolve(process.env.HERMES_DESKTOP_PLUGINS_DIR || path.join(os.homedir(), '.hermes/desktop-plugins'))
const lite = process.env.LITE === '1' || process.argv.includes('--lite')
const outDir = path.resolve(here, process.env.OUT_DIR || (lite ? 'dist-lite' : 'dist'))
const srcDir = path.join(desktopDir, 'src')

if (!fs.existsSync(path.join(srcDir, 'sdk/index.ts'))) {
  console.error(`Hermes Desktop source not found at ${desktopDir} (set HERMES_DESKTOP_DIR)`)
  process.exit(1)
}

const requireFromDesktop = createRequire(path.join(desktopDir, 'package.json'))
const importFromDesktop = async id => import(pathToFileURL(requireFromDesktop.resolve(id)).href)

const { build } = await importFromDesktop('vite')
const react = (await importFromDesktop('@vitejs/plugin-react')).default
const tailwindcss = (await importFromDesktop('@tailwindcss/vite')).default

const pkgDir = name => path.dirname(requireFromDesktop.resolve(`${name}/package.json`))
const reactDir = pkgDir('react')
const reactDomDir = pkgDir('react-dom')
const driverDir = path.dirname(requireFromDesktop.resolve('driver.js'))

// Fill the placeholders in src/host.css with absolute paths before Tailwind sees it.
const hostCssPaths = {
  name: 'vibe:host-css-paths',
  enforce: 'pre',
  transform(code, id) {
    if (!id.split('?')[0].endsWith(path.join('src', 'host.css'))) {
      return null
    }

    return code
      .replace("'@desktop/styles.css'", JSON.stringify(path.join(srcDir, 'styles.css')))
      .replace("'@desktop-src-dir'", JSON.stringify(srcDir))
      .replace(
        "@source '@desktop-plugins-dir';",
        fs.existsSync(pluginsDir) ? `@source ${JSON.stringify(pluginsDir)};` : ''
      )
  }
}

// --lite: drop syntax highlighting (shiki and all its grammars) and mermaid diagrams. The Desktop
// reaches both only through dynamic import() with plain-text fallbacks.
const liteStub = path.join(here, 'src/lite/unavailable.ts')
const liteStubs = {
  name: 'vibe:lite-stubs',
  enforce: 'pre',
  resolveId(id) {
    return lite && /^(shiki|@shikijs\/[^/]+|mermaid|@streamdown\/code|react-shiki)(\/.*)?$/.test(id) ? liteStub : null
  }
}

// Load the bundle as a classic script: module scripts are blocked on file:// origins.
const htmlTemplate = fs.readFileSync(path.join(here, 'src/index.html'), 'utf8')

const emitHtml = {
  name: 'vibe:emit-html',
  generateBundle() {
    this.emitFile({ type: 'asset', fileName: 'index.html', source: htmlTemplate })
  }
}

await build({
  configFile: false,
  root: here,
  base: './',
  mode: 'production',
  cacheDir: path.join(here, '.vite-cache'),
  logLevel: 'info',
  define: { 'process.env.NODE_ENV': JSON.stringify('production') },
  plugins: [liteStubs, hostCssPaths, react(), tailwindcss(), emitHtml],
  css: { postcss: { plugins: [] } },
  resolve: {
    alias: {
      '@/debug/dev-only': path.join(srcDir, 'debug/dev-only.noop.ts'),
      '@': srcDir,
      '@hermes/plugin-sdk': path.join(srcDir, 'sdk/index.ts'),
      '@hermes/shared/billing': path.resolve(desktopDir, '../shared/src/billing-types.ts'),
      '@hermes/shared/color': path.resolve(desktopDir, '../shared/src/color.ts'),
      '@hermes/shared': path.resolve(desktopDir, '../shared/src'),
      'driver.js/dist/driver.js.iife.js?raw': `${path.join(driverDir, 'driver.js.iife.js')}?raw`,
      'driver.js/dist/driver.js.iife.js': path.join(driverDir, 'driver.js.iife.js'),
      react: reactDir,
      'react-dom': reactDomDir,
      'react/jsx-dev-runtime': path.join(reactDir, 'jsx-dev-runtime.js'),
      'react/jsx-runtime': path.join(reactDir, 'jsx-runtime.js'),
      'react-router': pkgDir('react-router'),
      '@tanstack/react-query': pkgDir('@tanstack/react-query'),
      '@nanostores/react': pkgDir('@nanostores/react'),
      nanostores: pkgDir('nanostores')
    },
    dedupe: ['react', 'react-dom', 'react-router', '@tanstack/react-query', 'nanostores']
  },
  build: {
    outDir,
    emptyOutDir: true,
    assetsDir: 'assets',
    target: 'safari16',
    sourcemap: false,
    minify: true,
    cssCodeSplit: false,
    chunkSizeWarningLimit: 100_000,
    reportCompressedSize: false,
    rolldownOptions: {
      input: path.join(here, 'src/host.tsx'),
      output: {
        format: 'iife',
        codeSplitting: false,
        entryFileNames: 'assets/host.js',
        assetFileNames: info => (info.names?.[0]?.endsWith('.css') ? 'assets/host.css' : 'assets/[name]-[hash][extname]')
      }
    }
  }
})

const files = fs.readdirSync(path.join(outDir, 'assets'))
const total = files.reduce((sum, f) => sum + fs.statSync(path.join(outDir, 'assets', f)).size, 0)
console.log(`\nvibevory-pluginhost${lite ? ' (lite)' : ''} -> ${outDir} (${files.length} assets, ${(total / 1024 / 1024).toFixed(2)} MB)`)
