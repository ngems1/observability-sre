{{- define "opsdesk.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "opsdesk.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/part-of: opsdesk
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "opsdesk.selectorLabels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "opsdesk.secretName" -}}
{{- if .Values.secrets.create -}}
{{ include "opsdesk.fullname" . }}-secrets
{{- else -}}
{{ required "secrets.existingSecret is required when secrets.create=false" .Values.secrets.existingSecret }}
{{- end -}}
{{- end -}}

{{- define "opsdesk.image" -}}
{{ printf "%s:%s" .Values.image.repository (.Values.image.tag | toString) }}
{{- end -}}

{{/* Shared env for every container: config map + secret + chaos switches */}}
{{- define "opsdesk.envFrom" -}}
- configMapRef:
    name: {{ include "opsdesk.fullname" . }}-config
- secretRef:
    name: {{ include "opsdesk.secretName" . }}
{{- end -}}

{{- define "opsdesk.chaosEnv" -}}
- name: OPSDESK_CHAOS_LATENCY_MS
  value: {{ .Values.chaos.latencyMs | quote }}
- name: OPSDESK_CHAOS_ERROR_RATE
  value: {{ .Values.chaos.errorRate | quote }}
- name: OPSDESK_CHAOS_WORKER_FAIL_RATE
  value: {{ .Values.chaos.workerFailRate | quote }}
{{- end -}}
