{{/* Sources of the secrets backup that are switched on. */}}
{{- define "secrets-backup.sources" -}}
{{- $out := list -}}
{{- range .Values.secrets_backup.sources -}}
{{- if or (not .enabled_by) (index $.Values .enabled_by) -}}
{{- $out = append $out . -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end -}}
