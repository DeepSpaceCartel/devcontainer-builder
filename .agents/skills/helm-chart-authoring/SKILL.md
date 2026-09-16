---
name: helm-chart-authoring
description: Gotchas learned authoring minimal Helm charts for disposable Kubernetes test fixtures - ConfigMap changes not restarting pods, PodSecurity admission blocking privileged pods per-namespace, probe design, and deploying from external chart repos ad hoc. Use when writing or debugging a Helm chart, or when `helm upgrade --install --wait` behaves unexpectedly.
---

# Helm chart authoring gotchas

Concrete lessons from building `charts/test-registry` and
`charts/test-git-server` (disposable BDD test fixtures) in this repo.

## A ConfigMap/Secret *data* change does not restart pods

Kubernetes only rolls a Deployment when its **pod template** changes. A
Deployment that mounts a ConfigMap by name and only changes that ConfigMap's
*content* on `helm upgrade` will not restart - the running pod keeps
whatever the ConfigMap held when it started, silently. This bit us hard: an
initContainer seeds a repo's content once at pod startup from a ConfigMap,
and `helm upgrade` with new seed content appeared to succeed but the old pod
(and its stale seeded content) kept running.

Fix - the standard idiom: add a `checksum/<name>` pod-template annotation
computed from the rendered ConfigMap/Secret, so the pod template itself
changes whenever the referenced content does:

```yaml
spec:
  template:
    metadata:
      annotations:
        checksum/seed-config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

After adding this, verify the rollout actually happened - don't trust
`helm upgrade --wait` returning success alone:

```bash
kubectl get rs -n <ns> -l app.kubernetes.io/instance=<release>   # a NEW ReplicaSet at desired=1, OLD one at desired=0
kubectl get pods -n <ns> -l app.kubernetes.io/instance=<release> -o jsonpath='{.items[0].metadata.creationTimestamp}'
```

## PodSecurity admission is per-namespace and blocks silently-ish

A namespace's `pod-security.kubernetes.io/enforce` label determines what
pod specs are even allowed to be created there - `restricted`/`baseline`
reject `securityContext.privileged: true` outright (needed for BuildKit-like
workloads). `helm upgrade --install --wait` on such a rejection does **not**
surface a clear error - it just times out with `Error: context deadline
exceeded`, because the pod was never created at all. The real reason only
shows up in events:

```bash
kubectl get events -n <ns> --sort-by='.lastTimestamp' | grep -i forbidden
# Error creating: pods "..." is forbidden: violates PodSecurity "baseline:latest": privileged ...
```

Fix: either deploy into a namespace already labeled permissively (check
first: `kubectl get ns <ns> -o jsonpath='{.metadata.labels}'`), or create
your own with the label it needs:

```bash
kubectl create namespace <ns>
kubectl label namespace <ns> pod-security.kubernetes.io/enforce=privileged
```

Don't assume `default` is permissive - it commonly enforces `baseline`,
while a namespace already running a privileged workload (e.g. a `buildkit`
namespace) is a signal it's already labeled `privileged`.

## Readiness/liveness probes: use tcpSocket for anything auth-gated or non-HTTP

`httpGet` probes only treat 2xx/3xx as success. An endpoint that correctly
returns 401 when unauthenticated (e.g. a registry with auth enabled) will
permanently fail an `httpGet /v2/` probe even though the service is
perfectly healthy. Use `tcpSocket` instead for anything where "accepts a
connection" is the real health signal - also the only option for
non-HTTP protocols (git-daemon, SSH, raw TCP services):

```yaml
readinessProbe:
  tcpSocket:
    port: http
  initialDelaySeconds: 2
  periodSeconds: 3
```

## Deploying an external chart without `helm repo add`

You don't need to persist a repo entry to use someone else's chart once:

```bash
helm upgrade --install <release> <chart-name> --repo <https://chart-repo-url> \
  -n <namespace> --set-string someKey="multi\nline\nvalue" --wait --timeout 180s
```

For multiline/TOML-shaped values, either `--set-string key=$'line1\nline2\n'`
or (more readably) a `-f /tmp/values.yaml` file with a YAML block scalar
(`key: |`) - both pass through to the chart's `values.yaml` unchanged.

## `_helpers.tpl` naming pattern used across every chart in this repo

```tpl
{{- define "<chart-name>.fullname" -}}
{{- .Release.Name }}-{{ .Chart.Name }}
{{- end -}}

{{- define "<chart-name>.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
```

Keep the `<chart-name>.` prefix on every `define` unique per chart - a
generic `fullname`/`labels` name works fine within one chart but collides
if anything ever composes charts as subcharts.
