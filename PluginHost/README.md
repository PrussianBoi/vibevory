# Plugin host

Runs Hermes Desktop disk plugins (`~/.hermes/desktop-plugins/<id>/plugin.js`) inside the Mac app,
with the Desktop's own plugin SDK, loader, gateway client and UI components.

- `src/`: the host page (`host.tsx`, API notes in its header) and the fake Electron bridge (`bridge.ts`).
- `dist/`: the built page (lite build: no shiki or mermaid), committed. CI copies it into
  `VibeVory.app/Contents/Resources/PluginHost/`; `VoryMac/Plugins/PluginHost.swift` loads it.

Rebuild (needs a Hermes checkout with `apps/desktop` installed):

    npm install
    HERMES_DESKTOP_DIR=~/.hermes/hermes-agent/apps/desktop OUT_DIR=dist node build.mjs --lite

Tailwind scans `~/.hermes/desktop-plugins` at build time, so rebuild after adding a plugin
whose classes the Desktop itself does not use.

Tests (headless Chromium): `npm run test:mock`, `npm run test:bearer`, `npm test` (live backend).
