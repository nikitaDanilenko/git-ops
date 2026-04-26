{{- define "pubquiz-server.labels" -}}
app.kubernetes.io/name: pubquiz-server
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "pubquiz-server.databaseHost" -}}
{{- .Release.Name }}-postgres
{{- end }}
