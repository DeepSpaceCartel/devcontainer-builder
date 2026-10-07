// `npm run test:feature -- features/<name>.feature [...]`: only the given
// feature files. A plain `npm test -- <file>` runs EVERYTHING, because
// cucumber-js merges command-line paths with cucumber.mjs's
// features/**/*.feature (deprecated behavior it warns about) - which on a
// small cluster means hours, not minutes.
import base from './cucumber.mjs';

const files = (process.env.FEATURES ?? '').split(/\s+/).filter(Boolean);
if (files.length === 0) {
  throw new Error('test:feature: name the feature files, e.g. npm run test:feature -- features/health.feature');
}

export default { ...base, paths: files };
