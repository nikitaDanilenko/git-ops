{{- define "pubquiz-frontend.labels" -}}
app.kubernetes.io/name: pubquiz-frontend
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
