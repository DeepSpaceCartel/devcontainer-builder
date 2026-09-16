// Extracted from common.steps.js so cli.steps.js can reuse the same
// substitution mechanism for its command/file-content templating.

export function trackNamedValue(world, name, value) {
  world.namedValues ??= {};
  world.namedValues[name] = value;
}

// Sorted longest-name-first: some registered names are literal substrings
// of others (e.g. "registry-url" inside "authed-registry-url") - replacing
// the shorter one first would corrupt an unresolved occurrence of the
// longer one before it gets its own turn.
export function substituteNamedValues(world, text) {
  const entries = Object.entries(world.namedValues ?? {}).sort((a, b) => b[0].length - a[0].length);
  return entries.reduce((result, [name, value]) => result.replaceAll(name, value), text);
}
