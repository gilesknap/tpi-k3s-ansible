{{- /* Shared by the containers of the offsite-backup CronJob. */}}
{{- /* The context is a dict: o (offsite_backup), t (the target: see
cronjob-offsite.yaml). */}}
{{- define "offsite-backup.env" -}}
- name: TARGET
  value: {{ .t.kind | quote }}
- name: DEST_ROOT
  value: {{ .t.root | quote }}
- name: AGE_RECIPIENT
  value: {{ .o.age_recipient | quote }}
- name: RCLONE_SECRET
  value: /secret/rclone.conf
- name: PATH
  value: /tools:/usr/local/bin:/usr/bin:/bin
- name: RCLONE_RETRIES
  value: "5"
- name: RCLONE_LOW_LEVEL_RETRIES
  value: "20"
{{- if eq .t.kind "drive" }}
# 16M chunks: the memory each upload holds, and Drive's resumable upload
# unit. Retries ride out Drive's rate limits.
- name: RCLONE_DRIVE_CHUNK_SIZE
  value: 16M
# Deletions (pruning, failed partial uploads) skip the Drive's trash, whose
# contents still count against the quota.
- name: RCLONE_DRIVE_USE_TRASH
  value: "false"
{{- else }}
# 16M parts, 4 at a time: the memory a large upload holds (B2's default is
# 96M parts).
- name: RCLONE_B2_CHUNK_SIZE
  value: 16M
- name: RCLONE_B2_UPLOAD_CONCURRENCY
  value: "4"
# A deletion only hides the file: its versions stay, under Object Lock,
# until their retention ends and the bucket's lifecycle rule removes them.
# Never true (the key cannot delete a locked version anyway).
- name: RCLONE_B2_HARD_DELETE
  value: "false"
{{- end }}
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
