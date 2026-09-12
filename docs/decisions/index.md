<title>Decision log</title>

# Decision log

Architecture Decision Records — each one captures a single real design
decision, the context that led to it, and its honest trade-offs, so
nobody has to reconstruct "why did we do it this way?" from git blame
later. See [adr.github.io](https://adr.github.io/) for the convention
this follows. Numbers are sequential and never reused, even for a
rejected or superseded decision — a reference to "ADR-0003" always
points at the same file.

This is a different kind of document from
[`docs/claude/plans/`](https://github.com/DeepSpaceCartel/devcontainer-builder/tree/main/docs/claude/plans):
a plan is written *before* a change lands, to think through how to make
it; an ADR is a durable record of a decision *already made*, kept
accurate after the fact (superseded by a new ADR when circumstances
change, never rewritten in place).

| # | Decision | Status |
|---|---|---|
| [0001](0001-remote-buildkit-builder.md) | Remote BuildKit builder, no local Docker-in-Docker | accepted |
| [0002](0002-credentials-never-touch-argv-or-urls.md) | Credentials never touch argv, env history, or the clone URL | accepted |
| [0003](0003-registry-resolution-via-mapping-rules.md) | Registry resolution via server-side mapping rules | accepted |
| [0004](0004-ssh-host-key-verification-always-enforced.md) | SSH host key verification is always enforced | accepted |
| [0005](0005-bdd-suite-on-thomas.md) | The BDD suite runs on Thomas, a real-command framework | accepted |
| [0006](0006-privileged-test-namespace-via-chart.md) | A reusable chart owns every test namespace, not `--create-namespace` | accepted |
| [0007](0007-structured-registry-auth-and-auto-rendered-settings.md) | Structured registry auth, and an auto-rendered settings file | accepted |
| [0008](0008-image-existence-and-deletion-endpoints.md) | `GET`/`DELETE /image` for existence checks and best-effort deletion | accepted |
