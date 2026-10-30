# Kafka UI

Web UI for browsing topics, messages, consumer groups and broker config.
Uses **kafbat/kafka-ui**, the actively maintained fork of the former `provectuslabs/kafka-ui`.

- URL: `https://<HOMELAB_DOMAIN>:8080`, behind the gateway's sign-in (no published port of its own)
- Cluster is pre-configured (`kafka:9092`); `DYNAMIC_CONFIG_ENABLED=false` keeps the config in the compose file.

It has no login of its own any more: the homelab sign-in protects it, and anyone signed in can use it — including deleting topics and producing messages.
