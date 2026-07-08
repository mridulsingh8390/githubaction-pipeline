{{/* Fully qualified app name — uses the release name directly for simplicity. */}}
{{- define "sample-multicloud-app.fullname" -}}
{{ .Release.Name }}
{{- end -}}

{{/* Common labels applied to all resources. */}}
{{- define "sample-multicloud-app.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/* Selector labels — must stay stable across upgrades (no version/chart labels here). */}}
{{- define "sample-multicloud-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Ingress class / annotation preset per controller. Values in
.Values.ingress.annotations are merged in afterward and take precedence
over anything set here, so callers can always override a specific key.
*/}}
{{- define "sample-multicloud-app.ingressClassName" -}}
{{- if eq .Values.ingress.controller "agic" -}}
azure-application-gateway
{{- else if eq .Values.ingress.controller "alb" -}}
alb
{{- else if eq .Values.ingress.controller "gce" -}}
gce
{{- else -}}
nginx
{{- end -}}
{{- end -}}

{{- define "sample-multicloud-app.ingressBaseAnnotations" -}}
{{- if eq .Values.ingress.controller "agic" }}
kubernetes.io/ingress.class: azure/application-gateway
{{- else if eq .Values.ingress.controller "alb" }}
kubernetes.io/ingress.class: alb
{{- else if eq .Values.ingress.controller "gce" }}
kubernetes.io/ingress.class: gce
{{- else }}
kubernetes.io/ingress.class: nginx
{{- end }}
{{- end -}}
