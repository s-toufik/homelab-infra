# Kafka UI

Web UI for browsing topics, messages, consumer groups and broker config.
Uses **kafbat/kafka-ui**, the actively maintained fork of the former `provectuslabs/kafka-ui`.

- URL: http://<server>:8080
- Cluster is pre-configured (`kafka:9092`); `DYNAMIC_CONFIG_ENABLED=false` keeps the config in the compose file.

Login form authentication is required (`KAFKA_UI_USER`/`KAFKA_UI_PASSWORD` from `.env`). Keep `BIND_ADDR=127.0.0.1` or put it behind a reverse proxy with TLS if your LAN isn't trusted — the UI can delete topics and produce messages.
