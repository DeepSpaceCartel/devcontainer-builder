#!/usr/bin/env node
// Dumps the real, generated OpenAPI document to a file - run after `npm run
// build`, before `mkdocs build`, so the docs site can bundle a static copy
// (see docs/reference/API.md#bundled-api-docs) without a running service.
// Never hand-authored: this is the exact same document GET
// /documentation/json serves from a real running instance.
// An env var, not a CLI positional - build.js's own loadServiceConfig()
// parses process.argv itself (strict: true, rejects any argument it
// doesn't recognize), so this script can't add a positional of its own
// without that call throwing.
import { writeFile } from "node:fs/promises";
import { buildApp } from "../dist/server.js";

const outPath = process.env.OPENAPI_OUTPUT_PATH ?? "openapi.json";

const app = await buildApp();
await app.ready();
await writeFile(outPath, JSON.stringify(app.swagger(), null, 2));
await app.close();

console.log(`wrote ${outPath}`);
