# cAdvisor

Per-container CPU, memory, network and filesystem metrics, scraped by Prometheus on `cadvisor:8080`.

It runs as its own container instead of Alloy's embedded cAdvisor because Docker 29 stores images in the containerd image store. cAdvisor versions before v0.54.0 (including the one embedded in older Alloy releases) can't map containers in that layout: they log `failed to identify the read-write layer ID` and export no per-container series.

Useful queries:

```promql
sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m]))   # CPU cores per container
sum by (name) (container_memory_working_set_bytes{name!=""})             # memory per container
```
