# Kafka UI

Web UI for browsing topics, messages, consumer groups and broker config.
Uses **kafbat/kafka-ui**, the actively maintained fork of the former `provectuslabs/kafka-ui`.

- URL: http://<server>:8080
- Cluster is pre-configured (`kafka:9092`); `DYNAMIC_CONFIG_ENABLED=false` keeps the config in the compose file.

There is **no authentication** by default. Keep `BIND_ADDR=127.0.0.1` or put it behind a reverse proxy with auth if your LAN isn't trusted. The UI can delete topics and produce messages.
