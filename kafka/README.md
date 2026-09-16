# Kafka

Single-node Apache Kafka in **KRaft mode** (no ZooKeeper), broker and controller in one process.

| Listener  | Address                          | Use from                     |
|-----------|----------------------------------|------------------------------|
| PLAINTEXT | `kafka:9092`                     | other containers in the stack |
| EXTERNAL  | `${KAFKA_EXTERNAL_HOST}:9094`    | the host or your LAN         |
| CONTROLLER| `kafka:9093`                     | internal KRaft quorum only   |

Set `KAFKA_EXTERNAL_HOST` in `.env` to the server's LAN IP (or DNS name) if clients connect from another machine; otherwise they receive `localhost` in the metadata and fail to connect.

## Useful commands

```bash
# Create a topic
docker exec -it kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --create --topic demo --partitions 3 --replication-factor 1

# List topics
docker exec -it kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Produce / consume
docker exec -it kafka /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic demo
docker exec -it kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic demo --from-beginning
```

## Notes

- `KAFKA_CLUSTER_ID` is fixed at first start; changing it later on an existing volume will prevent the broker from starting.
- Retention: 7 days, capped at 10 GiB per partition. Adjust `KAFKA_LOG_RETENTION_*`.
- Heap is 1 GiB; the rest of the 2 GiB limit is left to the OS page cache, which Kafka relies on heavily.
- No authentication/TLS: fine on a trusted LAN, do not expose port 9094 to the internet.
