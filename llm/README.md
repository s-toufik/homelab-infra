# LLM (llama.cpp)

Two CPU inference servers built on the official `ghcr.io/ggml-org/llama.cpp:server` image. Both expose an **OpenAI-compatible API** with **tool calling**, and **Prometheus metrics**.

| Service | Model | Quantization | Use for | From containers | From your devices |
|---|---|---|---|---|---|
| `llm-large` | Qwen3-8B (`qwen3-8b`) | Q4_K_M (~5 GB) | Better answers, multi-step tool use | `http://llm-large:8080/v1` | `http://<BIND_ADDR>:8090/v1` |
| `llm-small` | Qwen3.5-2B (`qwen3.5-2b`) | Q8_0 (~2 GB) | Fast replies, routing, simple tool calls | `http://llm-small:8080/v1` | `http://<BIND_ADDR>:8091/v1` |

Both run with **thinking disabled** (`enable_thinking: false`), so answers are short and start immediately.

## First start

Models download from Hugging Face on first start into the `homelab_llm-models` volume (about 7 GB total), and are reused afterwards.

```bash
make up-llm
make llm-logs          # watch the download, Ctrl+C when "server is listening"
make llm-status
```

## Test

```bash
make llm-ask                              # large model
make llm-ask M=small Q="Explain KRaft in one sentence"
make llm-tools                            # checks both models produce a tool call
```

## Use from code

```python
from openai import OpenAI
client = OpenAI(base_url="http://llm-large:8080/v1", api_key="not-needed")
resp = client.chat.completions.create(model="qwen3-8b", messages=[{"role": "user", "content": "Hi"}], tools=[...])
```

## Change a model

Edit `.env`, for example:

```bash
LLM_LARGE_MODEL=unsloth/Qwen3.5-9B-GGUF:Q4_K_M
LLM_LARGE_ALIAS=qwen3.5-9b
```

then `make recreate S=llm-large`. Any GGUF on Hugging Face works with `-hf <repo>:<quant>`. For a Qwen3.5 model, add `--no-mmproj` to its command in `compose.yml` unless you need image input.

## Tuning

| Variable | Default | Effect |
|---|---|---|
| `LLM_*_THREADS` | 6 / 4 | CPU threads. Keep the sum at or below the 10 physical cores |
| `LLM_*_CTX` | 8192 | Context window in tokens. Higher = more RAM |
| `--parallel` in compose | 1 / 2 | Simultaneous requests. Context is split between them |

The memory limits (8 GB / 4 GB) include the model and its context. If a container is OOM-killed, lower `CTX` or raise its limit.

## Metrics

Prometheus scrapes `/metrics` on both servers (job `llama-cpp`). Grafana dashboard: **Homelab → LLM (llama.cpp)**.
