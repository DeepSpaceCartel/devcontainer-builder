#!/usr/bin/env bash
# Restores the agent skills pinned in skills-lock.json (gitignored under
# .agents/skills, next to the four committed ones) and points Claude Code's
# .claude/skills at them - Claude Code doesn't read .agents/skills itself.
# Runs on every workspace start (as updateContentCommand), before
# postCreateCommand.sh: idempotent, and must not depend on anything that
# script sets up.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# npx fails with ENOENT when npm's global prefix has no lib/ (e.g. the
# ~/.npm-global prefix typescript-node.sh sets, persisted in $HOME).
mkdir -p "$(npm config get prefix)/lib"

# Only when a pinned skill is missing: the restore downloads every skill
# again, and this runs on every start.
missing=$(node -e '
  const fs = require("fs");
  const skills = Object.keys(JSON.parse(fs.readFileSync("skills-lock.json", "utf8")).skills);
  console.log(skills.filter((s) => !fs.existsSync(`.agents/skills/${s}/SKILL.md`)).join(" "));
')
if [ -n "$missing" ]; then
  echo "Restoring skills from skills-lock.json (missing: $missing)..."
  npx -y skills@1.7.1 experimental_install
fi

mkdir -p .claude
if [ ! -e .claude/skills ]; then
  ln -s ../.agents/skills .claude/skills
fi
