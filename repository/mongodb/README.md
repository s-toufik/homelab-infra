# MongoDB

MongoDB 7.0 (8.x refuses to start on the server's Linux kernel, SERVER-121912), standalone, with root authentication; agent-runtime keeps its conversation checkpoints there. The WiredTiger cache is capped at 1 GiB so it doesn't compete with the rest of the homelab (the default would be about half the server's memory). Settings in [`values.yaml.gotmpl`](values.yaml.gotmpl).

- From pods: `mongodb://<user>:<password>@mongodb:27017/?authSource=admin`, the account from Secret `mongodb`
- From the tailnet's devices: `<domain>:27017` (the Tailscale address only)
- Shell: `make mongosh`

The root account is created from Secret `mongodb` when its volume is first initialised; changing the Secret later doesn't change the password.
