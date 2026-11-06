# Kafka

Apache Kafka 4.x in KRaft mode: one node, broker and controller together, no ZooKeeper. Settings in [`values.yaml.gotmpl`](values.yaml.gotmpl).

| Listener | Address | Used by |
|---|---|---|
| PLAINTEXT | `kafka:9092` | pods in the homelab |
| EXTERNAL | `<domain>:9094` | the tailnet's devices (the Tailscale address only) |
| CONTROLLER | `localhost:9093` | the node itself (KRaft) |

Topics are created on first use (3 partitions), kept 7 days and at most 10 GiB per partition.

```bash
make topics                        # list
make topic-create TOPIC=demo       # create (PARTITIONS=3)
make consume TOPIC=demo            # read from the beginning
make groups                        # consumer groups and their lag
```

Browse it in [Kafka UI](../kafka-ui/README.md) at `https://<domain>:8080`.
