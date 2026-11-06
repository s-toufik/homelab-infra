# MongoDB Exporter

Exposes MongoDB metrics in Prometheus format on `mongodb-exporter:9216/metrics` (inside the cluster only), signed in to MongoDB with the account of Secret `mongodb`. Prometheus finds it from its pod's `metrics:` annotation ([`values.yaml.gotmpl`](values.yaml.gotmpl)).

`mongodb_up` is `1` while the exporter can reach the database; homelab-ui shows it as MongoDB's status.
