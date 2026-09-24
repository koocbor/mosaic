---
icon: fontawesome/solid/dharmachakra
title: Quick Start on Kubernetes
---

<!--
SPDX-FileCopyrightText: 2025 Delos Data Inc
SPDX-License-Identifier: Apache-2.0
-->

This guide deploys Mosaic on a Kubernetes cluster with Helm and monitors collective metrics from a vLLM reference workload.
It is the Kubernetes equivalent of the [Quick Start](./quickstart.md), which uses docker compose.

# Prerequisites

## Hardware

A minimum of 2 GPUs is required to generate collective metrics.
This tutorial assumes a node equipped with 2 NVIDIA GPUs.

## Software

- A Kubernetes cluster, version 1.25 or later
- [Helm](https://helm.sh/docs/intro/install/) 3 or later
- [kubectl](https://kubernetes.io/docs/tasks/tools/) configured for the cluster
- The [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html), which provides the GPU device plugin, the `nvidia` RuntimeClass and GPU node labels

!!! note
    If you use the NVIDIA device plugin without the GPU Operator, label the GPU nodes with `nvidia.com/gpu.present=true`.
    If `nvidia` is the default container runtime, also set `nvidia.dcgmExporter.runtimeClassName=""`.

# Environment Setup

``` bash title="Clone the Mosaic repository"
git clone https://github.com/open-mosaic/mosaic.git
cd mosaic
```

# Launch Mosaic

The Mosaic Helm chart deploys the LGTM (Loki, Grafana, Tempo, Mimir) stack, the pipeline analyzer, the GPU and system exporters, and the vLLM reference workload with the Mosaic profiler plugin.

``` bash title="Install the Mosaic chart"
helm install mosaic ./deployments/charts/mosaic \
  --namespace mosaic --create-namespace
```

The exporters run as DaemonSets.
Node and process exporters run on every node, and the GPU exporter runs on GPU nodes.
Prometheus discovers them, and the vLLM metrics endpoint, through the Kubernetes API, so no scrape configuration needs to be generated.

!!! tip
    If the GPU Operator already runs dcgm-exporter, add `--set nvidia.dcgmExporter.enabled=false`.
    For AMD GPUs, use `--set nvidia.enabled=false,amd.enabled=true,processExporter.vendor=amd`.
    See the [chart README](https://github.com/open-mosaic/mosaic/blob/main/deployments/charts/mosaic/README.md) for all options.

The vLLM pod serves `Qwen/Qwen3-8B` with a tensor parallel size of 2.
Downloading and loading the model can take several minutes:

``` bash title="Wait for vLLM"
kubectl -n mosaic rollout status deploy/mosaic-vllm --timeout=30m
```

!!! tip
    If `kubectl -n mosaic logs deploy/mosaic-vllm` shows `Waiting for 1 local, 0 remote core engine proc(s) to start.` and does not proceed further,
    disable NCCL peer-to-peer transfers by adding `NCCL_P2P_DISABLE=1` to `vllm.env` in a values file:

    ```yaml
    vllm:
      env:
        - name: VLLM_LOGGING_LEVEL
          value: DEBUG
        - name: NCCL_P2P_DISABLE
          value: "1"
    ```

    Then apply it with `helm upgrade mosaic ./deployments/charts/mosaic -n mosaic -f <values-file>`.

# Verification

## Confirm Model Status

Forward the vLLM and Grafana ports to your machine:

``` bash
kubectl -n mosaic port-forward svc/mosaic-vllm 8080:8080 &
kubectl -n mosaic port-forward svc/mosaic-otel-lgtm 3000:3000 &
```

Verify that the model is being served correctly:

``` bash
curl -s localhost:8080/v1/models | jq '.data[].root'
```

Expected Output: `"Qwen/Qwen3-8B"`

## Verify Metrics Generation

Trigger an inference request to generate workload and populate the Mosaic metrics.

```bash
curl -s localhost:8080/v1/completions -H "Content-Type: application/json" -d '{
  "model": "Qwen/Qwen3-8B",
  "prompt": "Once upon a time",
  "max_tokens": 512
}' | jq
```

After the request completes, you can observe the updated metrics via Grafana dashboard at [http://localhost:3000](http://localhost:3000).

# Monitor Your Own Workloads

Point the Mosaic profiler plugin of any workload in the cluster at the Mosaic service:

``` bash
NCCL_PROFILER_OTEL_TELEMETRY_ENDPOINT=http://mosaic-otel-lgtm.mosaic.svc:4318
```

To deploy only the observability stack and exporters, install the chart with `--set vllm.enabled=false`.

# Multi-Node Workloads

The reference workload runs on a single node.
Multi-node workloads need pods to reach the backend network for RDMA, usually with the [Multus](https://github.com/k8snetworkplumbingwg/multus-cni) CNI and the [SR-IOV network device plugin](https://github.com/k8snetworkplumbingwg/sriov-network-device-plugin).
Support for this is tracked in [issue #30](https://github.com/open-mosaic/mosaic/issues/30).

# Clean Up

``` bash
helm uninstall mosaic --namespace mosaic
kubectl -n mosaic delete pvc mosaic-vllm-cache
```

The model cache is kept on uninstall, so delete it explicitly if you no longer need it.
