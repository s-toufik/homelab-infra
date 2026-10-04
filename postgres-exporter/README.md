# PostgreSQL Exporter

Exposes PostgreSQL metrics in Prometheus format on `postgres-exporter:9187/metrics` (inside Docker only). Prometheus scrapes it (see `prometheus/prometheus.yml`).

`pg_up` is `1` while the exporter can reach the database; homelab-ui shows it as PostgreSQL's status.
