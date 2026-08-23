# Reproducing the llama.cpp Slot-State PD PoC

This procedure reproduces the mechanism tested by this repository:

1. Prefill on a Windows Main host using local CUDA plus a Windows CUDA RPC node.
2. Keep the Prefill KV cache in Main host RAM.
3. Save slot 0 to a state file.
4. Transfer that single state file to a separate Windows M6.
5. Restore it into the same model on an M6 CPU-only server.
6. Submit the byte-identical Prompt and verify `cache_n`, `prompt_n`, and Decode timings.

The procedure does not use PR #27058 or `--prefill-node`.

## 1. Fixed identities

Use the values in:

- `manifests/build.json`
- `manifests/model.json`
- `manifests/placement.json`

The tested model is:

```text
Qwen/Qwen3-30B-A3B-GGUF
Qwen3-30B-A3B-Q4_K_M.gguf
18,556,685,824 bytes
SHA-256 0d003f6662faee786ed5da3e31b29c978de5ae5d275c8794c606a7f3c01aa8f5
```

The tested llama.cpp revision is:

```text
build 10107
commit c0bc8591e8815c63cb01dd3f051a8b0df02501c9
RPC protocol 4.0.3
```

Do not restore a state into a different model, quantization, tokenizer, KV type, or unverified llama.cpp build.

## 2. Machines

All three test nodes run Windows.

| Node | Role | Important hardware |
|---|---|---|
| Main | Prefill, save, transfer | RTX 4070 Ti SUPER 16 GB |
| SUB | CUDA RPC device | GTX 1660 6 GB |
| M6 | CPU-only Restore/Decode | Ryzen 5 7640HS, 48 GB RAM |

Use a trusted isolated LAN only. The RPC and example state-transfer protocol do not provide transport encryption or general hostile-input protection.

## 3. Prepare the repository and config

Place a copy of this repository on Main and M6. An ASCII-only runtime path is recommended on Windows.

Copy:

```text
config/config.example.json
```

to:

```text
config/config.json
```

Edit all local paths and the three exact LAN addresses. Set:

```json
"confirmed": true
```

only after checking every value. The scripts refuse to run while it is false.

The sample IP addresses are examples, not discovery targets. The scripts do not scan the LAN and connect only to addresses explicitly configured by the operator.

## 4. Install identical llama.cpp binaries

Install the complete build directory, including backend DLLs, on every applicable node. Do not mix individual executables and DLLs from different builds.

On Main and M6, capture:

```powershell
& $LlamaServer --version
& $LlamaServer --help
& $LlamaServer --list-devices
```

On SUB, capture:

```powershell
& $RpcServer --help
```

The SUB startup log must identify RPC protocol `4.0.3` and expose only the GTX 1660 CUDA device.

Before treating the run as binary-identical, add SHA-256 hashes of every distributed exe/DLL to `SHA256SUMS`. The original experiment did not preserve a complete public per-node DLL hash manifest, so this remains a documented limitation.

## 5. Verify the model on Main and M6

Run on both machines:

```powershell
Get-Item -LiteralPath 'D:\models\Qwen3-30B-A3B-Q4_K_M.gguf' |
  Select-Object FullName,Length

Get-FileHash -Algorithm SHA256 -LiteralPath `
  'D:\models\Qwen3-30B-A3B-Q4_K_M.gguf'
```

Expected byte size and SHA are in `manifests/model.json`. Do not proceed on a mismatch.

## 6. Start the Windows SUB RPC server

In an elevated PowerShell on SUB:

```powershell
& '.\scripts\sub-windows\start-rpc.ps1' `
  -ConfigPath '.\config\config.json'
```

The script starts only the configured executable, binds only the configured SUB address/port, requests `CUDA0`, and records a PID file. It does not expose a CPU RPC device.

Verify the SUB log contains the GTX 1660, CUDA0, the selected bind endpoint, and RPC protocol.

## 7. Start the Main Prefill server

On Main:

```powershell
& '.\scripts\main\start-prefill.ps1' `
  -ConfigPath '.\config\config.json'
```

The tested server arguments are generated from config and include:

```text
--rpc ${SUB_IP}:50052
--split-mode layer
--tensor-split 1,3
--n-gpu-layers 49
--fit off
--no-kv-offload
--cache-ram 0
--parallel 1
--slot-save-path ${MAIN_SLOTS}
--slots
--ctx-size 40960
--cache-type-k f16
--cache-type-v f16
--flash-attn off
--metrics
--load-mode none
```

Before Prefill, inspect the load log. The selected placement must be close to the evidence in `manifests/placement.json` and must show host KV with no CUDA/RPC KV buffer.

## 8. Prefill and save

Choose one exact case:

```powershell
& '.\scripts\main\prefill-save.ps1' `
  -ConfigPath '.\config\config.json' -Case 4k
```

or:

```powershell
& '.\scripts\main\prefill-save.ps1' `
  -ConfigPath '.\config\config.json' -Case 16k
```

The script:

- verifies Prompt bytes/SHA,
- submits `/completion` with `n_predict=0`,
- uses `cache_prompt=true`, `id_slot=0`, `temperature=0`, `seed=1234`,
- calls `POST /slots/0?action=save`,
- records `n_saved`, `n_written`, `save_ms`, state bytes, and state SHA.

Do not continue unless the server remains alive and the state counters are positive.

## 9. Start the M6 CPU-only Decode server

On M6:

```powershell
& '.\scripts\m6\start-decode.ps1' `
  -ConfigPath '.\config\config.json'
```

The tested arguments include:

```text
--n-gpu-layers 0
--no-kv-offload
--cache-ram 0
--parallel 1
--ctx-size 32768
--cache-type-k f16
--cache-type-v f16
--flash-attn off
--host 127.0.0.1
--load-mode none
```

The script rejects a Decode process that loads CUDA, cuBLAS, or ggml-rpc modules.

## 10. Transfer the state

First start one receiver on M6 from an elevated PowerShell:

```powershell
& '.\scripts\m6\receive-state.ps1' `
  -ConfigPath '.\config\config.json' -Case 4k
```

Then send the matching state once from Main:

```powershell
& '.\scripts\main\send-state.ps1' `
  -ConfigPath '.\config\config.json' -Case 4k
```

Use `16k` on both sides for the 16K case.

The transfer protocol is `llama-pd-slot-single-file-v1`:

1. little-endian Int32 JSON-header length,
2. UTF-8 JSON header,
3. exactly `header.length` state bytes,
4. length-prefixed JSON acknowledgement.

The receiver accepts one connection from the configured Main IP, writes a `.partial` file with `FileMode.CreateNew`, checks byte count and SHA-256, moves it to the final filename only after verification, and removes its temporary firewall rule in `finally`.

## 11. Restore and Decode

On M6:

```powershell
& '.\scripts\m6\restore-decode.ps1' `
  -ConfigPath '.\config\config.json' -Case 4k
```

The script:

1. revalidates state and Prompt SHA,
2. calls `POST /slots/0?action=restore`,
3. requires `n_restored == n_saved` and `n_read == n_written`,
4. submits the byte-identical Prompt with `n_predict=2048`,
5. measures streaming TTFT and request wall time,
6. requires `cache_n >= n_saved - 2` and `prompt_n <= 2`,
7. records the raw response and generated output.

The expected cache counters from the published runs are:

```text
4K:  cache_n=3999,  prompt_n=1
16K: cache_n=15999, prompt_n=1
```

## 12. Stop only managed processes

Examples:

```powershell
& '.\scripts\stop-managed-process.ps1' `
  -ConfigPath '.\config\config.json' -Role main

& '.\scripts\stop-managed-process.ps1' `
  -ConfigPath '.\config\config.json' -Role m6

& '.\scripts\stop-managed-process.ps1' `
  -ConfigPath '.\config\config.json' -Role sub
```

The stop script reads the saved PID, verifies the executable path, attempts PID-specific normal termination, waits ten seconds, and only then force-stops that PID. It never terminates processes by image name.

## 13. Compare with published evidence

Published evidence is under:

```text
results/4k/
results/16k/
results/summary.csv
```

The 16K `815.933453 s` value is explicitly a composite of measured components from linked sessions. It is not a single uninterrupted end-to-end wall time. See `results/16k/run-manifest.json`.

The 4K client wall time is materially larger than server `predicted_ms`; both are preserved in raw results and must not be treated as interchangeable.

## 14. Success criteria

Mechanism success requires all of the following:

- state bytes/SHA match after transfer,
- positive and matching save/restore counters,
- restored cache is actually reused,
- full Prompt Prefill is not repeated on M6,
- Decode process is CPU-only,
- generated tokens are positive,
- no matching assertion, allocation, CUDA, or RPC error,
- the protected unrelated RPC process is unchanged if one exists.

Output-language quality is reported separately. The published 16K run completed 2,048 generated tokens but did not reach its requested Japanese final answer.
