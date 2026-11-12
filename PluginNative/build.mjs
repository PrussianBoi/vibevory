// Builds the runtime into one classic script for JavaScriptCore (no modules, no DOM).
import { build } from 'esbuild'
await build({
  entryPoints: ['src/runtime.js'],
  bundle: true,
  format: 'iife',
  platform: 'neutral',
  mainFields: ['module', 'main'],
  target: 'safari17',
  minify: true,
  legalComments: 'none',
  define: { 'process.env.NODE_ENV': '"production"' },
  outfile: '../VoryMac/Plugins/plugin-runtime.js'
})
console.log('built ../VoryMac/Plugins/plugin-runtime.js')
