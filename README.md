# llama.cpp Slot-State PD PoC — RPC Distributed Prefill + Disaggregated Decode

## Externally Orchestrated Distributed Prefill (multi-machine RPC) → CPU-only Decode

**Status: Experimental PoC v0.2 / reproduction package included**

This repository documents an experimental Disaggregated Prefill/Decode workflow built from existing llama.cpp functionality. It does **not** use PR #27058 or `--prefill-node`.

```text
Main RTX 4070 Ti SUPER + Windows GTX 1660 RPC
                         |
                         v
              distributed Prefill
                         |
                  slot-state save
                         |
                  verified transfer
                         |
                         v
             GMKtec M6 CPU/RAM-only
                 Restore + Decode
```

The important success check is not Restore alone. The Decode request must reuse the restored cache instead of performing the full Prompt Prefill again.

## Reproduce

Start with [REPRODUCING.md](REPRODUCING.md). The repository includes:

- exact 4K and 16K Prompts under [`prompts/`](prompts/),
- model/build/hardware/placement manifests under [`manifests/`](manifests/),
- an editable [`config/config.example.json`](config/config.example.json),
- sanitized PowerShell orchestration under [`scripts/`](scripts/),
- raw sanitized result JSON and run manifests under [`results/`](results/),
- artifact hashes in [`SHA256SUMS`](SHA256SUMS).

The GGUF model and slot-state binaries are not redistributed.

## Fixed model and build

| Item | Value |
|---|---|
| Model repository | `Qwen/Qwen3-30B-A3B-GGUF` |
| Filename | `Qwen3-30B-A3B-Q4_K_M.gguf` |
| Architecture | `qwen3moe` |
| Quantization | `Q4_K_M` |
| Size | `18,556,685,824 bytes` |
| SHA-256 | `0d003f6662faee786ed5da3e31b29c978de5ae5d275c8794c606a7f3c01aa8f5` |
| llama.cpp build | `10107` |
| llama.cpp commit | `c0bc8591e8815c63cb01dd3f051a8b0df02501c9` |
| RPC protocol | `4.0.3` |

The published 4K/16K results use Q4_K_M, not the Q6_K file considered during early planning. See [`manifests/model.json`](manifests/model.json).

## Hardware roles

| Node | Hardware | Role |
|---|---|---|
| Main | Intel Core Ultra 7 265K, RTX 4070 Ti SUPER 16 GB | Prefill host, local CUDA, state save/send |
| SUB | Windows, GTX 1660 6 GB | remote CUDA RPC device |
| M6 | GMKtec M6, Ryzen 5 7640HS, 48 GB RAM | CPU/RAM-only Restore/Decode |

Exact OS builds, Main/SUB RAM, driver version, NIC details, and a complete public binary/DLL hash manifest were not captured and remain limitations. They are represented as `null` or unverified fields in the manifests rather than being inferred.

## Actual model and KV placement

```text
CUDA0 / RTX 4070 Ti SUPER model buffer : 12,769.53 MiB
RPC0  / GTX 1660 model buffer          :  4,754.91 MiB
CPU/host model tensor buffer           :      0.00 MiB
Host KV cache                          : yes
CUDA/RPC KV cache detected             : no
```

The final selected run was **not** a three-way model-weight split. Model weights were placed on the two GPUs; Main RAM held host KV/state/runtime data. See [`manifests/placement.json`](manifests/placement.json).

## Selected settings

Prefill:

```text
--rpc ${SUB_IP}:50052
--split-mode layer
--tensor-split 1,3
--n-gpu-layers 49
--fit off
--no-kv-offload
--cache-ram 0
--parallel 1
--ctx-size 40960
--cache-type-k f16
--cache-type-v f16
--flash-attn off
--load-mode none
```

M6 Decode:

```text
--n-gpu-layers 0
--no-kv-offload
--cache-ram 0
--parallel 1
--ctx-size 32768
--cache-type-k f16
--cache-type-v f16
--flash-attn off
--load-mode none
```

The reproduction scripts generate the complete commands, including model, slot, log, host, and port arguments.

## Results

| Metric | 4K | 16K |
|---|---:|---:|
| Prompt tokens | 4,000 | 16,000 |
| Actual generated tokens | 2,048 | 2,048 |
| Normal RPC Prefill | 60.868650 tok/s | 40.872818 tok/s |
| PD-run Prefill | 62.583465 tok/s | 41.139123 tok/s |
| Normal RPC Decode | 5.000774 tok/s | 3.488489 tok/s |
| M6 CPU-only Decode | 10.959625 tok/s | 5.032398 tok/s |
| Slot-state size | 393,281,180 bytes | 1,573,121,180 bytes |
| State transfer | 4.743025 s | 18.287224 s |
| Restore | 133.530 ms | 424.772 ms |
| `cache_n` | 3,999 | 15,999 |
| `prompt_n` | 1 | 1 |
| M6 Decode-local TTFT | 201.144 ms | 350.031 ms |
| M6 client Decode wall | 262.674544 s | 407.413153 s |
| Normal RPC total | 475.263493 s | 978.554932 s |
| PD measured-component total | 331.762561 s | 815.933453 s |

Both PD totals are sums of measured components from linked case artifacts, not a single client-observed uninterrupted E2E wall clock. The 16K total additionally combines the original Prefill/save/transfer session with a later M6 local rerun that completed the exact 2,048-token Decode. The source session IDs are recorded in each `run-manifest.json`.

For 4K, server Decode timing and client wall differ materially:

```text
server predicted_ms : 186,867.702 ms
client wall_ms      : 262,674.544 ms
difference          :  75,806.842 ms
```

Both values are preserved. The experiment did not establish the cause of this gap, so it is not attributed to a specific subsystem.

## Cache-reuse evidence

4K:

```text
n_restored = 4000
cache_n    = 3999
prompt_n   = 1
predicted_n = 2048
```

16K:

```text
n_restored = 16000
n_read     = 1573121180
cache_n    = 15999
prompt_n   = 1
predicted_n = 2048
```

The M6 did not perform the full Prompt Prefill again.

## Output-quality qualification

The 4K output reached the requested Japanese final answer. The 16K run completed exactly 2,048 generated tokens but consumed the budget inside English `<think>` output and did not reach the requested Japanese final answer.

```text
PD mechanism: success at 4K and 16K
Output quality: success at 4K, partial failure at 16K
```

## Benchmark scope

The current comparison is:

- **B:** normal RPC distributed Prefill and Decode,
- **C:** distributed Prefill, slot transfer, M6 CPU-only Decode.

The M6-only full-Prefill **A** baseline was not completed. This repository therefore does not claim that C is faster than M6-only inference. The published observations are single selected runs and do not establish statistical significance.

## Compatibility boundary

This PoC assumes:

- identical GGUF bytes and SHA-256,
- identical/compatible llama.cpp build and state format,
- identical KV cache types,
- compatible context/slot settings,
- byte-identical Prompt and tokenizer/chat-template behavior.

Cross-build, cross-model, cross-quantization, cross-tokenizer, and cross-KV-type state compatibility were not tested.

## Security

llama.cpp RPC and the included experimental state-transfer scripts are for a trusted isolated LAN only. Do not expose them to the public Internet. The example transport is not an authenticated or encrypted production protocol, and slot state may contain Prompt-derived information.

## Related upstream work

- [llama.cpp Issue #21266](https://github.com/ggml-org/llama.cpp/issues/21266)
- [llama.cpp PR #27058](https://github.com/ggml-org/llama.cpp/pull/27058)
- [llama.cpp RPC README](https://github.com/ggml-org/llama.cpp/blob/c0bc8591e8815c63cb01dd3f051a8b0df02501c9/tools/rpc/README.md)
- [llama-server README](https://github.com/ggml-org/llama.cpp/blob/c0bc8591e8815c63cb01dd3f051a8b0df02501c9/tools/server/README.md)

This repository documents an independent external orchestration approach and does not use PR #27058.
