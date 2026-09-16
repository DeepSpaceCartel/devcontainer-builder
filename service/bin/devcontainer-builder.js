#!/usr/bin/env node
// Thin CLI entrypoint for the published npm package - just runs the same
// compiled server dist/index.js already builds, so `npx
// @deepspacecartel/devcontainer-builder` (or a global `devcontainer-builder`
// after `npm install -g`) behaves identically to `node dist/index.js`/the
// Docker image's own ENTRYPOINT. All configuration is CLI flags/env
// vars/a settings file, already handled by src/config.ts - see
// docs/reference/CONFIGURATION.md, not anything parsed here.
import "../dist/index.js";
