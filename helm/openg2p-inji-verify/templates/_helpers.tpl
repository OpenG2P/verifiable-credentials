{{/*
Service account name for verify-service.
*/}}
{{- define "verify.serviceAccountName" -}}
{{- if .Values.verifyService.serviceAccount.create -}}
{{ default (printf "%s-%s" .Release.Name .Values.verifyService.nameOverride) .Values.verifyService.serviceAccount.name }}
{{- else -}}
{{ default "default" .Values.verifyService.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Fully-qualified name for verify-service.
*/}}
{{- define "verify.fullname" -}}
{{ printf "%s-%s" .Release.Name .Values.verifyService.nameOverride }}
{{- end -}}

{{/*
Standard labels.
*/}}
{{- define "verify.labels" -}}
app.kubernetes.io/name: {{ .Values.verifyService.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "verify.selectorLabels" -}}
app.kubernetes.io/name: {{ .Values.verifyService.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Environment for verify-service.

Two mutually exclusive shapes, selected by `stateless`:

  * stateless=true  -> the image's `local` Spring profile: in-memory HSQLDB,
                       schema created at boot, no DATABASE_* needed.
  * stateless=false -> the `default` profile, which requires every DATABASE_*
                       value and an external PostgreSQL.

Everything else is common, and `extraEnvVars` is applied last so an operator can
override any of it without a chart change.
*/}}
{{- define "verify.envVars" -}}
{{- $v := .Values.verifyService -}}
{{- if $v.stateless }}
- name: active_profile_env
  value: "local"
{{- else }}
- name: active_profile_env
  value: "default"
- name: DATABASE_HOST
  value: {{ include "common.tplvalues.render" (dict "value" $v.database.host "context" $) | quote }}
- name: DATABASE_PORT
  value: {{ $v.database.port | quote }}
- name: DATABASE_NAME
  value: {{ $v.database.name | quote }}
- name: DATABASE_SCHEMA
  value: {{ $v.database.schema | quote }}
- name: DATABASE_USERNAME
  value: {{ include "common.tplvalues.render" (dict "value" $v.database.username "context" $) | quote }}
- name: DATABASE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "common.tplvalues.render" (dict "value" $v.database.existingSecret "context" $) | quote }}
      key: {{ $v.database.existingSecretPasswordKey | quote }}
{{- end }}
{{- range $k, $val := $v.extraEnvVars }}
- name: {{ $k }}
  value: {{ include "common.tplvalues.render" (dict "value" $val "context" $) | squote }}
{{- end }}
{{- end -}}
