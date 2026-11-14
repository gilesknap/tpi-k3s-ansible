{{- /* Shared by both containers of the offsite-backup CronJob. */}}
{{- define "offsite-backup.env" -}}
- name: DRIVE_ROOT
  value: {{ printf "drive:%s" .Values.offsite_backup.drive_root | quote }}
- name: AGE_RECIPIENT
  value: {{ .Values.offsite_backup.age_recipient | quote }}
- name: RCLONE_SECRET
  value: /secret/rclone.conf
- name: PATH
  value: /tools:/usr/local/bin:/usr/bin:/bin
# 16M chunks: the memory each upload holds, and Drive's resumable upload
# unit. Retries ride out Drive's rate limits.
- name: RCLONE_DRIVE_CHUNK_SIZE
  value: 16M
- name: RCLONE_RETRIES
  value: "5"
- name: RCLONE_LOW_LEVEL_RETRIES
  value: "20"
{{- end }}

{{- define "offsite-backup.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end }}

{{- define "offsite-backup.resources" -}}
requests:
  cpu: 50m
  memory: 64Mi
limits:
  memory: 512Mi
{{- end }}

{{- define "offsite-backup.mounts" -}}
- name: rclone
  mountPath: /secret
  readOnly: true
- name: scripts
  mountPath: /scripts
  readOnly: true
- name: tools
  mountPath: /tools
  readOnly: true
- name: work
  mountPath: /work
{{- end }}
