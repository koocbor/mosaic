{{/*
SPDX-FileCopyrightText: 2025 Delos Data Inc
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Chart name
*/}}
{{- define "mosaic.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name, used as the prefix for all resources
*/}}
{{- define "mosaic.fullname" -}}
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
Common labels
*/}}
{{- define "mosaic.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for a component. Usage:
{{ include "mosaic.selectorLabels" (dict "ctx" . "component" "otel-lgtm") }}
*/}}
{{- define "mosaic.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mosaic.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Selector labels plus common labels for a component
*/}}
{{- define "mosaic.componentLabels" -}}
{{ include "mosaic.labels" .ctx }}
{{ include "mosaic.selectorLabels" . }}
{{- end }}

{{/*
Container image reference from an image values block. The tag defaults to the
chart's appVersion when empty. Usage:
{{ include "mosaic.image" (dict "image" .Values.vllm.image "ctx" $) }}
*/}}
{{- define "mosaic.image" -}}
{{- printf "%s:%s" .image.repository (toString (.image.tag | default .ctx.Chart.AppVersion)) }}
{{- end }}

{{/*
Pod annotations for Prometheus Kubernetes service discovery. The job annotation
is combined with the node name to form the job label (for example
node_exporter-gpu-node-1), matching file-sd-config-generate.sh. Usage:
{{ include "mosaic.scrapeAnnotations" (dict "job" "node_exporter" "port" 9100) }}
*/}}
{{- define "mosaic.scrapeAnnotations" -}}
mosaic.io/scrape: "true"
mosaic.io/job: {{ .job | quote }}
mosaic.io/port: {{ .port | quote }}
{{- with .path }}
mosaic.io/path: {{ . | quote }}
{{- end }}
{{- with .interval }}
mosaic.io/scrape-interval: {{ . | quote }}
{{- end }}
{{- with .timeout }}
mosaic.io/scrape-timeout: {{ . | quote }}
{{- end }}
{{- end }}

{{/*
Prometheus configuration: files/prometheus.yaml plus the Kubernetes service
discovery job and any extra scrape configs
*/}}
{{- define "mosaic.prometheusConfig" -}}
{{- $config := .Files.Get "files/prometheus.yaml" | fromYaml }}
{{- $scrapeConfigs := $config.scrape_configs | default list }}
{{- if .Values.lgtm.prometheus.kubernetesSd.enabled }}
{{- $scrapeConfigs = append $scrapeConfigs (include "mosaic.kubernetesScrapeConfig" . | fromYaml) }}
{{- end }}
{{- if and .Values.lgtm.prometheus.kubernetesSd.enabled .Values.nvidia.dcgmExporter.external.enabled }}
{{- $scrapeConfigs = append $scrapeConfigs (include "mosaic.externalDcgmScrapeConfig" . | fromYaml) }}
{{- end }}
{{- range .Values.lgtm.prometheus.extraScrapeConfigs }}
{{- $scrapeConfigs = append $scrapeConfigs . }}
{{- end }}
{{- $_ := set $config "scrape_configs" $scrapeConfigs }}
{{- toYaml $config }}
{{- end }}

{{/*
Scrape job for the pods annotated with mosaic.io/scrape in the release namespace
*/}}
{{- define "mosaic.kubernetesScrapeConfig" -}}
job_name: kubernetes-pods
kubernetes_sd_configs:
  - role: pod
    namespaces:
      names:
        - {{ .Release.Namespace }}
relabel_configs:
  - source_labels: [__meta_kubernetes_pod_annotation_mosaic_io_scrape]
    action: keep
    regex: "true"
  - source_labels: [__meta_kubernetes_pod_phase]
    action: drop
    regex: Pending|Succeeded|Failed
  - source_labels: [__address__, __meta_kubernetes_pod_annotation_mosaic_io_port]
    action: replace
    regex: '([^:]+)(?::\d+)?;(\d+)'
    replacement: $1:$2
    target_label: __address__
  - source_labels: [__meta_kubernetes_pod_annotation_mosaic_io_path]
    action: replace
    regex: (.+)
    target_label: __metrics_path__
  - source_labels: [__meta_kubernetes_pod_annotation_mosaic_io_scrape_interval]
    action: replace
    regex: (.+)
    target_label: __scrape_interval__
  - source_labels: [__meta_kubernetes_pod_annotation_mosaic_io_scrape_timeout]
    action: replace
    regex: (.+)
    target_label: __scrape_timeout__
  - source_labels: [__meta_kubernetes_pod_node_name]
    action: replace
    target_label: host
  - source_labels: [__meta_kubernetes_pod_annotation_mosaic_io_job, __meta_kubernetes_pod_node_name]
    action: replace
    separator: "-"
    target_label: job
{{- end }}

{{/*
Scrape job for an externally managed dcgm-exporter (for example the NVIDIA
GPU Operator's), living outside the release namespace. Matches pods in
nvidia.dcgmExporter.external.namespace by nvidia.dcgmExporter.external.podLabels
and produces the same job label (gpu_exporter-<node>) as the built-in
dcgm-exporter, so dashboards work unchanged regardless of the source.
*/}}
{{- define "mosaic.externalDcgmScrapeConfig" -}}
{{- $external := .Values.nvidia.dcgmExporter.external }}
job_name: gpu-operator-dcgm-exporter
kubernetes_sd_configs:
  - role: pod
    namespaces:
      names:
        - {{ $external.namespace }}
relabel_configs:
  {{- range $k, $v := $external.podLabels }}
  - source_labels: [__meta_kubernetes_pod_label_{{ regexReplaceAll "[^a-zA-Z0-9_]" $k "_" }}]
    action: keep
    regex: {{ $v | quote }}
  {{- end }}
  - source_labels: [__meta_kubernetes_pod_phase]
    action: drop
    regex: Pending|Succeeded|Failed
  - source_labels: [__address__]
    action: replace
    regex: '([^:]+)(?::\d+)?'
    replacement: '$1:{{ $external.port }}'
    target_label: __address__
  - source_labels: [__meta_kubernetes_pod_node_name]
    action: replace
    target_label: host
  - source_labels: [__meta_kubernetes_pod_node_name]
    action: replace
    separator: "-"
    target_label: job
    replacement: gpu_exporter-$1
{{- end }}
