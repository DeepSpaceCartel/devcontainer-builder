// Shared between server.ts's live GET /documentation registration
// (@fastify/swagger-ui's `theme.css` option) and
// scripts/export-swagger-ui.mjs's static bundle, so both ever apply the
// exact same override, never just one of them.
//
// The vendored swagger-ui.css renders every inline `code` span inside a
// markdown description (parameter/response/operation descriptions - real
// content from schemas.ts/server.ts `description` fields) with a fixed
// 5px/7px padding and 14px font-size - fine for a whole code block, but a
// short single-word span like `status` ends up as an oversized pill next
// to normal text, especially inside a narrow table cell. This matches
// GitHub's own well-tested inline-code sizing instead of guessing.
export const SWAGGER_UI_CUSTOM_CSS = `.swagger-ui .renderedMarkdown code {
  padding: 0.2em 0.4em;
  font-size: 85%;
}
`;
