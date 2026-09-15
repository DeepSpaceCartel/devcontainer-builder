{{- define "devcontainer-builder.fullname" -}}
{{- .Release.Name }}-{{ .Chart.Name }}
{{- end -}}

{{- define "devcontainer-builder.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "devcontainer-builder.secretName" -}}
{{- if .Values.registryAuth.existingSecret -}}
{{ .Values.registryAuth.existingSecret }}
{{- else -}}
{{ include "devcontainer-builder.fullname" . }}-registry-auth
{{- end -}}
{{- end -}}

{{- define "devcontainer-builder.gitCredentialsSecretName" -}}
{{- if .Values.gitCredentials.existingSecret -}}
{{ .Values.gitCredentials.existingSecret }}
{{- else -}}
{{ include "devcontainer-builder.fullname" . }}-git-credentials
{{- end -}}
{{- end -}}

{{- /*
Only ever invoked when existingConfigMap is set (inline rules flow
through the unified settings ConfigMap instead - see settingsJson below) -
no chart-rendered fallback name exists for this one.
*/ -}}
{{- define "devcontainer-builder.registryMappingConfigMapName" -}}
{{ .Values.registryMapping.existingConfigMap }}
{{- end -}}

{{- /*
Builds the real docker-config-JSON string from .Values.registryAuth.registries.
Each entry's registry/username/password is required, not silently
skipped, so a typo'd entry fails the render loudly instead of producing a
Secret with a silently-missing credential.
*/ -}}
{{- define "devcontainer-builder.dockerConfigJson" -}}
{{- $auths := dict -}}
{{- range $i, $r := .Values.registryAuth.registries -}}
{{- $registry := required (printf "registryAuth.registries[%d].registry is required" $i) $r.registry -}}
{{- $username := required (printf "registryAuth.registries[%d].username is required" $i) $r.username -}}
{{- $password := required (printf "registryAuth.registries[%d].password is required" $i) $r.password -}}
{{- $auths = set $auths $registry (dict "auth" (printf "%s:%s" $username $password | b64enc)) -}}
{{- end -}}
{{- dict "auths" $auths | toJson -}}
{{- end -}}

{{- /*
Builds the unified settings file content, mirroring config.ts's own
RawSettingsFile shape/nesting. gitCredentials is deliberately never
included here - GIT_CREDENTIALS_CONFIG_PATH always wins over any settings-
file copy of the same field (config.ts's dedicated-file-wins-entirely
precedence), so a copy here would be both inert and a needless duplicate
of sensitive material in a less-guarded ConfigMap. registryMapping.rules
is included only when existingConfigMap is unset, for the identical
reason - REGISTRY_MAPPING_CONFIG_PATH wins entirely whenever it's set.
*/ -}}
{{- define "devcontainer-builder.settingsJson" -}}
{{- $settings := dict -}}
{{- if .Values.buildkit.endpoint -}}
{{- $settings = set $settings "buildkit" (dict "endpoint" .Values.buildkit.endpoint) -}}
{{- end -}}
{{- $build := dict -}}
{{- if .Values.build.platforms -}}
{{- $build = set $build "platforms" .Values.build.platforms -}}
{{- end -}}
{{- if .Values.build.noCache -}}
{{- $build = set $build "noCache" .Values.build.noCache -}}
{{- end -}}
{{- if .Values.build.cacheFrom -}}
{{- $build = set $build "cacheFrom" .Values.build.cacheFrom -}}
{{- end -}}
{{- if .Values.build.cacheTo -}}
{{- $build = set $build "cacheTo" .Values.build.cacheTo -}}
{{- end -}}
{{- if ne .Values.build.mode "auto" -}}
{{- $build = set $build "mode" .Values.build.mode -}}
{{- end -}}
{{- if $build -}}
{{- $settings = set $settings "build" $build -}}
{{- end -}}
{{- $settings = set $settings "sshHostKeyPolicy" .Values.sshHostKeyPolicy -}}
{{- if and .Values.registryMapping.enabled (not .Values.registryMapping.existingConfigMap) -}}
{{- $settings = set $settings "registryMapping" (dict "rules" .Values.registryMapping.rules) -}}
{{- end -}}
{{- $settings | toJson -}}
{{- end -}}
