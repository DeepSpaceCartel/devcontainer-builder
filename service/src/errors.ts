// Thrown for user-fixable request problems discovered before or during a
// build that the up-front shape validation (schemas.ts) can't express on
// its own, e.g. a disallowed repository URL scheme or no registry resolving
// for a repository - server.ts maps this to 400, everything else to 500.
// Its own module (not build.ts) so the small validation modules build.ts
// depends on (git-url.ts, ...) can throw it without an import cycle.
export class BuildRequestError extends Error {}
