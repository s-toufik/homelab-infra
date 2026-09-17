# LLM (llama-swap)

One CPU inference server, [`llama-swap`](https://github.com/mostlygeek/llama-swap), fronting several `llama.cpp` models behind a single **OpenAI-compatible API**. Models aren't split across ports — pick one by name in the request's `model` field.

| Model | Total / active params | Quantization | Group |
|---|---|---|---|
| `granite4-7b` | 7B / 1B | Q4_K_M | always-on, preloaded |
| `lfm2-8b-a1b` | 8.3B / 1.5B | Q4_K_M | on-demand |
| `gigachat3.1-10b-a1.8b` | 10B / 1.8B | Q4_K_M | on-demand |
| `lfm2-24b-a2b` | 24B / 2.3B | Q4_K_M | on-demand |
| `gemma4-26b-a4b` | 26B / 4B | Q4_K_M (`UD-Q4_K_M`) | on-demand |
| `qwen3-30b-a3b` | 30.5B / 3.3B | Q4_K_M | on-demand |

See [`config.yml`](config.yml) for the exact `-hf <repo>:<quant>` source of each. All are MoE/hybrid models — the "active params" column is what actually drives inference cost per token, not the total.

Only `granite4-7b` runs **always-on** — it's preloaded at container startup (`hooks.on_startup.preload`) and never unloaded (`ttl: 0`). The other five are in the `on-demand` group with `swap: true`: requesting any one of them loads it and unloads whichever on-demand model was previously loaded, so **at most one on-demand model is resident at a time** alongside `granite4-7b`. Each on-demand model also has `ttl: 600` — it unloads on its own after 10 minutes idle, even without a different model being requested.

All models run with **thinking disabled** (`enable_thinking: false`), so answers are short and start immediately.

- From containers: `http://llm:8080/v1`
- From your devices: `http://<BIND_ADDR>:8090/v1`

## First start

Models download from Hugging Face on first use into the `homelab_llm-models` volume and are reused afterwards. `granite4-7b` downloads immediately on startup; each on-demand model downloads the first time it's requested — expect a long wait the first time you call a new one (the five on-demand models total roughly 60 GB).

```bash
make up-llm
make llm-logs          # watch the download, Ctrl+C when the model is loaded
make llm-status
```

## Test

```bash
make llm-ask                                              # granite4-7b (always-on)
make llm-ask M=qwen3-30b-a3b Q="Explain KRaft in one sentence"   # loads it on demand
```

## Use from code

```python
from openai import OpenAI
client = OpenAI(base_url="http://llm:8080/v1", api_key="not-needed")
resp = client.chat.completions.create(model="granite4-7b", messages=[{"role": "user", "content": "Hi"}], tools=[...])
```

Pass the `model` you want in each request — swapping which on-demand model is loaded happens automatically on the server side.

## Change a model

Edit `models` in [`config.yml`](config.yml), then apply with:

```bash
make recreate S=llm
```

`config.yml` is mounted as a single file, and hot-reload (`-watch-config`) hasn't reliably picked up edits on this host — always use `make recreate S=llm`, not a restart/reload, after changing it. Any GGUF on Hugging Face works with `-hf <repo>:<quant>`; check the exact quant filename in the repo first (some, like `gemma4-26b-a4b`, use non-standard tags such as `UD-Q4_K_M`).

Adding or swapping an on-demand model doesn't need a resource-limit change as long as it stays under the container's memory cap (see Tuning below) — just add it to the `on-demand` group's `members` list.

## Tuning

| Setting | Where | Effect |
|---|---|---|
| `--threads` | each model's `cmd` in `config.yml` | CPU threads while that model is active. `granite4-7b` gets 6 (always resident), on-demand models get 10 (only one runs at a time, alongside granite) |
| `--ctx-size` | each model's `cmd` in `config.yml` | Context window in tokens. Higher = more RAM |
| `--parallel` | each model's `cmd` in `config.yml` | Simultaneous requests. Context is split between them |
| `ttl` | each model's entry in `config.yml` | Seconds idle before auto-unload. `0` = never (used for `granite4-7b`); `600` = 10 min (all on-demand models) |
| `deploy.resources.limits` | `compose.yml` | Container-wide CPU/memory cap — must cover `granite4-7b` + the single largest on-demand model, not the sum of all of them |

If the container is OOM-killed, lower the active on-demand model's `--ctx-size` first — the largest one (`qwen3-30b-a3b`, ~18.6 GiB at Q4_K_M) plus `granite4-7b` puts you close to a 32 GiB host's ceiling already.

## Metrics

Prometheus scrapes each model's metrics through llama-swap's per-model proxy path, `/upstream/<model>/metrics` (job `llama-cpp` in `prometheus/prometheus.yml`) — one static target per model, always present even when that model isn't currently loaded (it'll just show as a failed/`down` scrape until it's loaded). Grafana dashboard: **Homelab → LLM (llama.cpp)**.
