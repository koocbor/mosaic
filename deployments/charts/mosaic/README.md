<!--
SPDX-FileCopyrightText: 2025 Delos Data Inc
SPDX-License-Identifier: Apache-2.0
-->

# Mosaic Helm Chart

This chart deploys Mosaic on Kubernetes. It is the Kubernetes counterpart of the docker compose files in `deployments/`:

| Component | Kind | Compose equivalent |
|-----------|------|--------------------|
| `otel-lgtm` (OpenTelemetry Collector, Prometheus, Loki, Tempo, Grafana) | Deployment | `docker-compose.yml` |
| `pipeline-analyzer` | Deployment | `docker-compose.yml` |
| `node-exporter`, `process-exporter` | DaemonSet | `*-gpu-monitoring/docker-compose.yml` |
| `dcgm-exporter` (NVIDIA) | DaemonSet | `nvidia-gpu-monitoring/docker-compose.yml` |
| `amd-device-exporter`, `gpu-pcie-exporter` (AMD) | DaemonSet | `amd-gpu-monitoring/docker-compose.yml` |
| `vllm` reference workload | Deployment | `docker-compose-vllm.yml` |

See the [Kubernetes quick start](../../../docs/docs/kubernetes.md) for a walkthrough.

## Install

```bash
helm install mosaic ./deployments/charts/mosaic -n mosaic --create-namespace
```

Install only the observability stack and system exporters (no GPU needed):

```bash
helm install mosaic ./deployments/charts/mosaic -n mosaic --create-namespace \
  --set vllm.enabled=false \
  --set nvidia.enabled=false
```

## Configuration files

The files under `files/` are symlinks to the configuration used by docker compose (`deployments/prometheus.yaml`, `deployments/dashboards/`, and so on). Edit the originals; both deployments pick up the change. Helm follows the symlinks and `helm package` embeds their contents.

The chart makes two additions to `prometheus.yaml` when rendering it:

- A `kubernetes-pods` job that discovers the exporters and the vLLM workload deployed by this chart. It scrapes pods in the release namespace that have the `mosaic.io/scrape: "true"` annotation. It sets the `host` label to the node name and the `job` label to `<exporter>-<node>`, the same labels `file_sd_configs/file-sd-config-generate.sh` produces, which the dashboards rely on.
- A `gpu-operator-dcgm-exporter` job when `nvidia.dcgmExporter.external.enabled` is `true`, discovering pods by label in `nvidia.dcgmExporter.external.namespace`. It produces the same `job: gpu_exporter-<node>` label as the built-in dcgm-exporter, so the dashboards work the same either way.
- Anything listed in `lgtm.prometheus.extraScrapeConfigs`.

Both Kubernetes service discovery jobs need matching RBAC to list/watch pods in the namespaces they scrape. The chart creates a Role/RoleBinding in the release namespace, and — only when `nvidia.dcgmExporter.external.enabled` is `true` — a second Role/RoleBinding in `nvidia.dcgmExporter.external.namespace`. That namespace must already exist; the chart does not create it.

Hosts outside the cluster can still be added through file service discovery with `lgtm.fileSd`:

```yaml
lgtm:
  fileSd:
    node1.yaml:
      - targets: ["10.0.0.1:9100"]
        labels:
          job: node_exporter-node1
          host: node1
```

## Images

The Mosaic images (`openmosaic/mosaic-vllm`, `openmosaic/pipeline-analyzer` and `openmosaic/gpu-pcie-exporter`) leave `tag` empty by default, which uses the chart's `appVersion`. Set `tag` to override it. The other images use the versions pinned in the docker compose files, except `grafana/otel-lgtm`, which uses `latest`.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `lgtm.image.repository` / `tag` | `grafana/otel-lgtm` / `latest` | Observability stack image |
| `lgtm.service.name` | `mosaic-otel-lgtm` | Service name. Workloads send OTLP to `http://<name>:4318` |
| `lgtm.service.type` | `ClusterIP` | Service type for Grafana, OTLP, Loki and Prometheus ports |
| `lgtm.persistence.enabled` | `false` | Store telemetry data on a PVC mounted at `/data` |
| `lgtm.persistence.size` | `20Gi` | PVC size |
| `lgtm.prometheus.kubernetesSd.enabled` | `true` | Discover chart exporters through the Kubernetes API |
| `lgtm.prometheus.extraScrapeConfigs` | `[]` | Extra Prometheus scrape configs |
| `lgtm.fileSd` | `{}` | File service discovery targets, keyed by file name |
| `pipelineAnalyzer.enabled` | `true` | Deploy the pipeline analyzer |
| `pipelineAnalyzer.image.repository` / `tag` | `openmosaic/pipeline-analyzer` / `""` | Pipeline analyzer image. An empty tag uses the chart's `appVersion` |
| `nodeExporter.enabled` | `true` | Deploy node-exporter on every node |
| `nodeExporter.port` | `9100` | Host port. Change it if another node exporter already runs on the nodes |
| `processExporter.enabled` | `true` | Deploy process-exporter on every node |
| `processExporter.vendor` | `nvidia` | Process matching config: `nvidia` or `amd` |
| `nvidia.enabled` | `true` | Deploy NVIDIA GPU exporters |
| `nvidia.dcgmExporter.enabled` | `true` | Deploy dcgm-exporter. Ignored when `nvidia.dcgmExporter.external.enabled` is `true` |
| `nvidia.dcgmExporter.runtimeClassName` | `nvidia` | RuntimeClass that exposes GPUs. Set to `""` if nvidia is the default runtime |
| `nvidia.dcgmExporter.nodeSelector` | `nvidia.com/gpu.present: "true"` | Nodes that run dcgm-exporter |
| `nvidia.dcgmExporter.external.enabled` | `false` | Scrape an externally managed dcgm-exporter (for example the GPU Operator's) instead of deploying one. See below |
| `nvidia.dcgmExporter.external.namespace` | `gpu-operator` | Namespace the external dcgm-exporter pods run in |
| `nvidia.dcgmExporter.external.podLabels` | `app: nvidia-dcgm-exporter` | Label selector matching the external dcgm-exporter pods |
| `nvidia.dcgmExporter.external.port` | `9400` | Metrics port exposed by the external dcgm-exporter |
| `amd.enabled` | `false` | Deploy AMD GPU exporters |
| `amd.deviceExporter.nodeSelector` | `feature.node.kubernetes.io/amd-gpu: "true"` | Nodes that run the AMD device exporter |
| `amd.pcieExporter.enabled` | `false` | Deploy the GPU PCIe exporter |
| `amd.pcieExporter.image.repository` / `tag` | `openmosaic/gpu-pcie-exporter` / `""` | GPU PCIe exporter image. An empty tag uses the chart's `appVersion` |
| `vllm.enabled` | `true` | Deploy the vLLM reference workload |
| `vllm.image.repository` / `tag` | `openmosaic/mosaic-vllm` / `""` | vLLM image with the Mosaic profiler plugin. An empty tag uses the chart's `appVersion` |
| `vllm.model` | `Qwen/Qwen3-8B` | Model to serve |
| `vllm.port` | `8080` | API port, which also serves the vLLM Prometheus metrics |
| `vllm.gpus` | `2` | GPUs requested through `vllm.gpuResourceName` |
| `vllm.tensorParallelSize` | `2` | vLLM tensor parallel size |
| `vllm.extraArgs` | see `values.yaml` | Extra `vllm serve` arguments |
| `vllm.env` | `VLLM_LOGGING_LEVEL=DEBUG` | Environment variables for the vLLM container |
| `vllm.hfTokenSecret.name` | `""` | Secret with a Hugging Face token, for gated models |
| `vllm.shmSize` | `16Gi` | Size of the in-memory `/dev/shm` used by NCCL |
| `vllm.cache.type` | `pvc` | Model cache: `pvc`, `hostPath` or `emptyDir` |
| `vllm.cache.size` | `50Gi` | Model cache PVC size |

Every component also accepts `resources`, `nodeSelector` and `tolerations`. The Deployments also accept `affinity`. See `values.yaml` for the full list.

## Notes

- The `mosaic-otel-lgtm` and `pipeline-analyzer` Services have fixed names, matching docker compose and `prometheus.yaml`. Install one release per namespace.
- The vLLM model cache PVC is kept on `helm uninstall` so models aren't downloaded again. Delete it with `kubectl delete pvc mosaic-vllm-cache`.
- The published images are built for `linux/amd64`.
