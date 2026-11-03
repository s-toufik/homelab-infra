# Kafka Exporter

Exposes Kafka topic and consumer-group metrics in Prometheus format on `kafka-exporter:9308/metrics` (and `https://<domain>:9308` through the gateway, signed in). Prometheus finds it from its pod's `metrics:` annotation ([`values.yaml.gotmpl`](values.yaml.gotmpl)).

Key metrics:

| Metric | Meaning |
|--------|---------|
| `kafka_topic_partition_current_offset` | latest offset per partition (rate = messages in/s) |
| `kafka_consumergroup_lag` | lag per group / topic / partition |
| `kafka_consumergroup_current_offset` | committed offset per group |
| `kafka_brokers` | number of brokers seen |

If the exporter crash-loops with a protocol/version error after a Kafka upgrade, adjust `--kafka.version` in [`values.yaml.gotmpl`](values.yaml.gotmpl).
