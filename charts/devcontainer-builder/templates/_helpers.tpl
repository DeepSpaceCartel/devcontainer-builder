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

{{- define "devcontainer-builder.registryMappingConfigMapName" -}}
{{- if .Values.registryMapping.existingConfigMap -}}
{{ .Values.registryMapping.existingConfigMap }}
{{- else -}}
{{ include "devcontainer-builder.fullname" . }}-registry-mapping
{{- end -}}
{{- end -}}
