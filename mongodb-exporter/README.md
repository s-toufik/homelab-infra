# MongoDB Exporter

Exposes MongoDB metrics in Prometheus format on `mongodb-exporter:9216/metrics` (inside Docker only). Prometheus scrapes it (see `prometheus/prometheus.yml`).

`mongodb_up` is `1` while the exporter can reach the database; homelab-ui shows it as MongoDB's status.
