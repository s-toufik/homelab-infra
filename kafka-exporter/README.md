# Kafka Exporter

Exposes Kafka topic and consumer-group metrics in Prometheus format on `:9308/metrics`. Prometheus scrapes it every 30 s (see `prometheus/prometheus.yml`).

Key metrics:

| Metric | Meaning |
|--------|---------|
| `kafka_topic_partition_current_offset` | latest offset per partition (rate = messages in/s) |
| `kafka_consumergroup_lag` | lag per group / topic / partition |
| `kafka_consumergroup_current_offset` | committed offset per group |
| `kafka_brokers` | number of brokers seen |

If the exporter crash-loops with a protocol/version error after a Kafka upgrade, adjust `--kafka.version` in `compose.yml`.
