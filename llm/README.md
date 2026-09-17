# LLM (llama-swap)

One CPU inference server, [`llama-swap`](https://github.com/mostlygeek/llama-swap), fronting one or more `llama.cpp` models behind a single **OpenAI-compatible API**. Models are no longer split across ports — pick one by name in the request's `model` field.

| Model | Quantization | Use for |
|---|---|---|
| `granite4-7b` | Q4_K_M (~5 GB) | Better answers, multi-step tool use |
| `qwen3.5-2b` | Q8_0 (~2 GB) | Fast replies, routing, simple tool calls |

Both models are `always-on` (see `groups` in [`config.yml`](config.yml)) — llama-swap keeps them loaded simultaneously rather than swapping one out to load the other. Both run with **thinking disabled** (`enable_thinking: false`), so answers are short and start immediately.

- From containers: `http://llm:8080/v1`
- From your devices: `http://<BIND_ADDR>:8090/v1`

## First start

Models download from Hugging Face on first start into the `homelab_llm-models` volume (about 7 GB total), and are reused afterwards.

```bash
make up-llm
make llm-logs          # watch the download, Ctrl+C when the model is loaded
make llm-status
```

## Test

```bash
make llm-ask                                          # granite4-7b
make llm-ask M=qwen3.5-2b Q="Explain KRaft in one sentence"
make llm-tools                                         # checks every model produces a tool call
```

## Use from code

```python
from openai import OpenAI
client = OpenAI(base_url="http://llm:8080/v1", api_key="not-needed")
resp = client.chat.completions.create(model="granite4-7b", messages=[{"role": "user", "content": "Hi"}], tools=[...])
```

## Change a model

Edit `models` in [`config.yml`](config.yml), for example:

```yaml
models:
  granite4-7b:
    cmd: |
      /app/llama-server ${common}
      -hf unsloth/Qwen3.5-9B-GGUF:Q4_K_M
      --ctx-size 8192 --parallel 1 --threads 6
    aliases: [granite4-7b]
    ttl: 0
```

then `make recreate S=llm` (llama-swap also hot-reloads `config.yml` on change since compose passes `-watch-config`, so a recreate isn't always necessary). Any GGUF on Hugging Face works with `-hf <repo>:<quant>`. For a Qwen3.5 model, add `--no-mmproj` unless you need image input.

## Tuning

| Setting | Where | Effect |
|---|---|---|
| `--threads` | each model's `cmd` in `config.yml` | CPU threads. Keep the sum of always-on models at or below the 10 physical cores |
| `--ctx-size` | each model's `cmd` in `config.yml` | Context window in tokens. Higher = more RAM |
| `--parallel` | each model's `cmd` in `config.yml` | Simultaneous requests. Context is split between them |
| `deploy.resources.limits` | `compose.yml` | Container-wide CPU/memory cap — must cover the sum of always-on models + headroom |

If the container is OOM-killed, lower a model's `--ctx-size` or raise the container's memory limit.

## Metrics

Prometheus scrapes each model's metrics through llama-swap's per-model proxy path, `/upstream/<model>/metrics` (job `llama-cpp` in `prometheus/prometheus.yml`). Grafana dashboard: **Homelab → LLM (llama.cpp)**.
