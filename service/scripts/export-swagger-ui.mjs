#!/usr/bin/env node
// Copies @fastify/swagger-ui's own static bundle - the exact same UI GET
// /documentation serves live - into a standalone folder, so the docs site
// can bundle it too (its own "HTTP API (Swagger UI)" nav entry, mkdocs.yml)
// without a running service. Run after export-openapi.mjs (needs its
// output as a sibling file), before `mkdocs build`.
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { SWAGGER_UI_CUSTOM_CSS } from "../dist/swagger-ui-theme.js";

const require = createRequire(import.meta.url);
const swaggerUiStaticDir = join(dirname(require.resolve("@fastify/swagger-ui/package.json")), "static");

const outDir = process.env.SWAGGER_UI_OUTPUT_DIR ?? "swagger-ui";

await mkdir(outDir, { recursive: true });
await cp(swaggerUiStaticDir, outDir, { recursive: true });

// The copied static/swagger-initializer.js doesn't exist in this bundle -
// server.ts's live GET /documentation route generates it per-request
// (lib/swagger-initializer.js), pointed at that request's own `./json`
// sibling route. There's no live route here, so this writes the
// equivalent initializer by hand, pointed at the sibling openapi.json
// export-openapi.mjs already wrote one directory up - same dom_id/
// presets/layout defaults server.ts's own fastifySwaggerUi registration
// uses, just a fixed `url` instead of one resolved from the current page.
await writeFile(
  join(outDir, "swagger-initializer.js"),
  `window.onload = function () {
  window.ui = SwaggerUIBundle({
    url: "../openapi.json",
    dom_id: "#swagger-ui",
    deepLinking: true,
    presets: [SwaggerUIBundle.presets.apis, SwaggerUIStandalonePreset],
    plugins: [SwaggerUIBundle.plugins.DownloadUrl],
    layout: "StandaloneLayout",
  });
};
`,
);

// Same override server.ts's live GET /documentation registration applies
// via @fastify/swagger-ui's own `theme.css` option (see
// swagger-ui-theme.ts) - written by hand here since there's no live
// plugin registration in a static export to hand it to instead, loaded
// after the vendored stylesheet so it wins on cascade order rather than
// patching the vendored file itself (regenerated from node_modules every
// run, so an in-place edit would be silently lost).
await writeFile(join(outDir, "custom.css"), SWAGGER_UI_CUSTOM_CSS);

const indexHtmlPath = join(outDir, "index.html");
const indexHtml = await readFile(indexHtmlPath, "utf8");
await writeFile(
  indexHtmlPath,
  indexHtml.replace(
    '<link rel="stylesheet" type="text/css" href="index.css" />',
    '<link rel="stylesheet" type="text/css" href="index.css" />\n    <link rel="stylesheet" type="text/css" href="./custom.css" />',
  ),
);

console.log(`wrote ${outDir}/`);
