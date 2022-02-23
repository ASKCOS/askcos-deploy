{{/*
Expand the name of the chart.
*/}}
{{- define "askcos.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "askcos.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "askcos.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a unified set of labels for various components of askcos
*/}}
{{- define "askcos.common.matchLabels" -}}
app.kubernetes.io/part-of: {{ include "askcos.name" . }}
app.kubernetes.io/release: {{ .Release.Name }}
{{- end }}

{{- define "askcos.common.metaLabels" -}}
helm.sh/chart: {{ include "askcos.chart" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "askcos.app.matchLabels" -}}
app.kubernetes.io/component: {{ .Values.app.name }}
{{ include "askcos.common.matchLabels" . }}
{{- end }}

{{- define "askcos.app.labels" -}}
{{ include "askcos.app.matchLabels" . }}
{{ include "askcos.common.metaLabels" . }}
{{- end }}

{{- define "askcos.nginx.matchLabels" -}}
app.kubernetes.io/component: {{ .Values.nginx.name }}
{{ include "askcos.common.matchLabels" . }}
{{- end }}

{{- define "askcos.nginx.labels" -}}
{{ include "askcos.nginx.matchLabels" . }}
{{ include "askcos.common.metaLabels" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "askcos.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "askcos.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create image pull secret
*/}}
{{- define "askcos.imagePullSecret" }}
{{- if .Values.imageCredentials }}
{{- with .Values.imageCredentials }}
{{- printf "{\"auths\":{\"%s\":{\"username\":\"%s\",\"password\":\"%s\",\"auth\":\"%s\"}}}" .registry .username .password (printf "%s:%s" .username .password | b64enc) | b64enc }}
{{- end }}
{{- end }}
{{- end }}
