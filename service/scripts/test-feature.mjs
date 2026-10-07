// Runs cucumber-js on just the feature files given as arguments (see
// cucumber.feature.mjs for why `npm test -- <file>` isn't enough).
import { spawnSync } from 'node:child_process';

const files = process.argv.slice(2).filter((a) => !a.startsWith('-'));
const flags = process.argv.slice(2).filter((a) => a.startsWith('-'));
const result = spawnSync('npx', ['cucumber-js', '-c', 'cucumber.feature.mjs', ...flags], {
  stdio: 'inherit',
  env: { ...process.env, FEATURES: files.join(' '), NODE_OPTIONS: `${process.env.NODE_OPTIONS ?? ''} --import tsx`.trim() },
});
process.exit(result.status ?? 1);
