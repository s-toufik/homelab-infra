# LLM (llama-swap)

One CPU inference server, [`llama-swap`](https://github.com/mostlygeek/llama-swap), fronting several `llama.cpp` models behind a single **OpenAI-compatible API**. Pick a model by name in the request's `model` field — there's no per-model port.

| Model | Hugging Face | Total / active params | Quantization | Availability |
|---|---|---|---|---|
| `granite4-7b` | [unsloth/granite-4.0-h-tiny-GGUF](https://huggingface.co/unsloth/granite-4.0-h-tiny-GGUF) | 7B / 1B | Q4_K_M | always on |
| `lfm2-8b-a1b` | [unsloth/LFM2-8B-A1B-GGUF](https://huggingface.co/unsloth/LFM2-8B-A1B-GGUF) | 8.3B / 1.5B | Q4_K_M | on demand |
| `gigachat3.1-10b-a1.8b` | [ai-sage/GigaChat3.1-10B-A1.8B-GGUF](https://huggingface.co/ai-sage/GigaChat3.1-10B-A1.8B-GGUF) | 10B / 1.8B | Q4_K_M | on demand |
| `lfm2-24b-a2b` | [LiquidAI/LFM2-24B-A2B-GGUF](https://huggingface.co/LiquidAI/LFM2-24B-A2B-GGUF) | 24B / 2.3B | Q4_K_M | on demand |
| `gemma4-26b-a4b` | [unsloth/gemma-4-26B-A4B-it-GGUF](https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF) | 26B / 4B | Q4_K_M | on demand |
| `qwen3-30b-a3b` | [unsloth/Qwen3-30B-A3B-GGUF](https://huggingface.co/unsloth/Qwen3-30B-A3B-GGUF) | 30.5B / 3.3B | Q4_K_M | on demand |

`granite4-7b` is always loaded and ready. Requesting any other model loads it (may take a while the first time — see First start) and unloads whichever on-demand model was loaded before; each also unloads on its own after 10 minutes idle. At most one on-demand model is resident at a time, alongside `granite4-7b`.

- From containers: `http://llm:8080/v1`
- From your devices: `http://<BIND_ADDR>:8090/v1`

## First start

Models download from Hugging Face on first use into the `homelab_llm-models` volume and are reused afterwards. `granite4-7b` downloads on startup; an on-demand model downloads the first time you request it — the first call to a new one can take a while (the five on-demand models total roughly 60 GB).

```bash
make up-llm
make llm-logs          # watch the download, Ctrl+C when the model is loaded
make llm-status
```

## Test

```bash
make llm-ask                                                    # granite4-7b (always-on)
make llm-ask M=qwen3-30b-a3b Q="Explain KRaft in one sentence"   # loads it on demand
```

## Use from code

```python
from openai import OpenAI
client = OpenAI(base_url="http://llm:8080/v1", api_key="not-needed")
resp = client.chat.completions.create(model="granite4-7b", messages=[{"role": "user", "content": "Hi"}], tools=[...])
```

Pass whichever `model` you want per request — swapping happens automatically.

## Check what's loaded right now

- Grafana → **Homelab → LLM (llama.cpp)** → "Currently Loaded Models" table.
- Or: `curl http://<BIND_ADDR>:8090/running`

A model that isn't listed isn't loaded.

## Change a model

Edit `models` in [`config.yml`](config.yml), then apply with:

```bash
make recreate S=llm
```

Always use `recreate`, not a restart — reload doesn't reliably pick up `config.yml` edits here. Any GGUF on Hugging Face works with `-hf <repo>:<quant>`; check the exact quant filename in the repo first (some use non-standard tags, e.g. `gemma4-26b-a4b` needs `UD-Q4_K_M`, not `Q4_K_M`).

Adding or swapping an on-demand model just means adding it to the `on-demand` group's `members` list — no resource-limit change needed as long as it stays under the container's memory cap (see Tuning).

**Don't add a Prometheus target for an on-demand model yourself** (e.g. copying `granite4-7b`'s target in `prometheus/prometheus.yml`) — it would force-load that model on every scrape. On-demand models are picked up automatically once loaded; see Metrics.

## Tuning

| Setting | Where | Effect |
|---|---|---|
| `--threads` | each model's `cmd` in `config.yml` | CPU threads while that model is active. `granite4-7b` gets 6 (always resident), on-demand models get 10 (only one runs at a time, alongside granite) |
| `--ctx-size` | each model's `cmd` in `config.yml` | Context window in tokens. Higher = more RAM |
| `--parallel` | each model's `cmd` in `config.yml` | Simultaneous requests. Context is split between them |
| `ttl` | each model's entry in `config.yml` | Seconds idle before auto-unload. `0` = never (`granite4-7b`); `600` = 10 min (all on-demand models) |
| `deploy.resources.limits` | `compose.yml` | Container-wide CPU/memory cap — must cover `granite4-7b` + the single largest on-demand model, not the sum of all of them |

If the container is OOM-killed, lower the active on-demand model's `--ctx-size` first — the largest one (`qwen3-30b-a3b`, ~18.6 GiB at Q4_K_M) plus `granite4-7b` puts you close to a 32 GiB host's ceiling already.

## Metrics

- `granite4-7b`: full generation-speed / tokens-per-minute panels, always populated.
- On-demand models: the same panels populate **for up to `ttl` seconds (10 min) after each load**, then go quiet even if the model happens to still be up — this is intentional (see `exporter/poll-running.py`), not a bug: continuously monitoring an on-demand model would otherwise reset its own idle timer and prevent it from ever unloading.

Grafana dashboard: **Homelab → LLM (llama.cpp)**.

### Verify an on-demand model still unloads after its `ttl`

Load one (e.g. `make llm-ask M=qwen3-30b-a3b`), then leave it idle for longer than its `ttl` (10 min) without sending it any more requests:

```bash
make llm-running
```

It should show `DOWN`.
