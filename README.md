# llama.cpp Slot-State PD PoC

## Experimental Disaggregated Prefill/Decode Using Distributed Prefill and CPU-Only Decode

**Status: Experimental Report v0.1**

> This repository documents an experimental Disaggregated Prefill/Decode (PD) setup built using existing llama.cpp functionality.
>
> At this stage, the primary purpose of the repository is to publish the experimental architecture and measured results. Exact llama.cpp build information, full commands, orchestration scripts, raw benchmark data, and complete reproduction instructions will be added in later revisions.

---

## 1. Overview

This experiment tests whether a prompt can be prefilled using multiple compute resources, saved as a llama.cpp slot state, transferred to another machine, restored there, and then decoded without re-running the full prompt prefill.

The Prefill side used:

* NVIDIA GeForce RTX 4070 Ti SUPER
* NVIDIA GeForce GTX 1660 via llama.cpp RPC
* Main PC system RAM

The Decode side used:

* AMD Ryzen 5 7640HS
* 48 GB system RAM
* CPU/RAM-only Decode

The Decode machine was a GMKtec M6.

The basic architecture was:

```text
             Prefill side

      RTX 4070 Ti SUPER
               +
       GTX 1660 via RPC
               +
          Main PC RAM
               |
               v
       Distributed Prefill
               |
               v
        llama.cpp slot state
               |
             SAVE
               |
        Network transfer
               |
               v

              Decode side

        Ryzen 5 7640HS
          CPU + RAM
               |
            RESTORE
               |
         Cache reuse
               |
               v
             Decode
```

The purpose was not merely to distribute model execution across multiple devices.

The goal was to physically separate the compute resources used for **Prefill** from those used for **Decode**, while transferring the already-computed prompt state between the two systems.

---

## 2. Relationship to llama.cpp's PD Development

llama.cpp has ongoing work related to Disaggregated Prefill/Decode.

This experiment does **not** use the in-development llama.cpp PD implementation.

Instead, it combines existing llama.cpp functionality:

* RPC distributed inference
* llama-server slot-state save
* llama-server slot-state restore
* external state transfer
* external orchestration
* cache-reuse verification
* switching from the Prefill system to the Decode system

The resulting flow is:

```text
RPC distributed Prefill
        |
        v
slot-state save
        |
        v
state transfer
        |
        v
restore on another machine
        |
        v
cache-reuse verification
        |
        v
CPU-only Decode
```

The PD concept itself is not novel.

The experimental feature of this PoC is that the PD workflow is orchestrated **outside llama.cpp**, without modifying llama.cpp itself and without relying on its in-development PD implementation.

In particular, a distributed llama.cpp RPC configuration is used as the Prefill engine, and its resulting slot state is transferred to a separate CPU/RAM-only Decode machine.

---

## 3. Why a Successful Restore Alone Was Not Considered Sufficient

A successful slot-state restore does not by itself prove that Prefill/Decode disaggregation has succeeded.

If the Decode machine restores the state but then performs a complete Prefill of the original prompt again, the intended PD behavior has not actually been achieved.

For this reason, the experiment checked:

```text
n_restored
cache_n
prompt_n
```

For the 16K test:

```text
n_restored = 16000
cache_n    = 15999
prompt_n   = 1
```

This means that, after restoring the transferred state, 15,999 of the 16,000 prompt tokens were reused from the cache.

Only one prompt token was processed on the Decode machine before generation continued.

For the 4K test:

```text
cache_n  = 3999
prompt_n = 1
```

Therefore, the Decode machine did not perform a full Prefill of the original prompt.

---

## 4. 4K / 16K Measured Results

| Metric                       |                4K |                 16K |
| ---------------------------- | ----------------: | ------------------: |
| Prompt tokens                |             4,000 |              16,000 |
| Requested generation tokens  |             2,048 |               2,048 |
| Actual generated tokens      |             2,048 |               2,048 |
| Normal RPC Prefill           |   60.868650 tok/s |     40.872818 tok/s |
| PD Prefill                   |   62.583465 tok/s |     41.139123 tok/s |
| Normal RPC Decode            |    5.000774 tok/s |      3.488489 tok/s |
| M6 CPU-only Decode           |   10.959625 tok/s |      5.032398 tok/s |
| M6 / normal RPC Decode ratio |           2.1916x |             1.4426x |
| Slot-state size              | 393,281,180 bytes | 1,573,121,180 bytes |
| State transfer time          |        4.743025 s |         18.287224 s |
| Restore time                 |        133.530 ms |          424.772 ms |
| `cache_n`                    |             3,999 |              15,999 |
| `prompt_n`                   |                 1 |                   1 |
| Prompt cache reuse           |           99.975% |           99.99375% |
| M6 TTFT                      |        201.144 ms |          350.031 ms |
| M6 Decode wall time          |      262.674544 s |        407.413153 s |
| Normal RPC total time        |      475.263493 s |        978.554932 s |
| PD measured component total  |      331.762561 s |        815.933453 s |
| Total-time reduction with PD |            30.19% |              16.62% |
| Minimum available RAM on M6  |        15.023 GiB |          13.688 GiB |

---

## 5. 4K Test

A 4,000-token prompt was processed on the distributed Prefill system.

The resulting slot state was saved and transferred to the M6 Decode machine.

After Restore:

```text
cache_n  = 3999
prompt_n = 1
```

The prompt cache reuse rate was therefore:

```text
99.975%
```

The M6 then generated exactly 2,048 tokens using CPU/RAM-only Decode.

Measured Decode speed:

```text
10.959625 tok/s
```

The generated output successfully reached the requested Japanese-language response.

Result:

```text
PD_CACHE_REUSE_SUCCESS
```

---

## 6. 16K Test

A 16,000-token prompt was processed on the distributed Prefill system.

The resulting slot-state size was:

```text
1,573,121,180 bytes
```

Measured network transfer time from the Main system to the M6:

```text
18.287224 s
```

This is an actual measured transfer time, not a theoretical network-bandwidth estimate.

Restore time on the M6:

```text
424.772 ms
```

Restore result:

```text
n_restored = 16000
n_read     = 1573121180

cache_n    = 15999
prompt_n   = 1
```

Prompt cache reuse:

```text
99.99375%
```

The M6 then performed CPU/RAM-only Decode.

Generation result:

```text
predicted_n = 2048
exact_2048  = true
```

Decode speed:

```text
5.032398 tok/s
```

TTFT:

```text
350.031 ms
```

The requested 2,048 generated tokens were completed.

---

## 7. 16K End-to-End Timing

The 16K PD total is based entirely on measured components.

```text
Prefill          388.938326 s
state save         0.843698 s
state transfer    18.287224 s
prompt transfer    0.026280 s
Restore            0.424772 s
M6 Decode        407.413153 s
--------------------------------
Total            815.933453 s
```

The measured total for the normal RPC configuration was:

```text
978.554932 s
```

Under this specific experimental configuration, the PD path therefore reduced total measured processing time by:

```text
16.62%
```

For the 4K test, the corresponding reduction was:

```text
30.19%
```

These results do **not** imply that PD is universally faster.

Performance depends on factors including:

* model architecture
* model quantization
* context length
* state size
* Prefill hardware
* Decode hardware
* RPC topology
* memory placement
* network bandwidth and latency

The numbers above apply only to the tested configuration.

---

## 8. State Integrity Verification

SHA-256 of the slot state used for the 16K test:

```text
e443bd56caa2706a2efbb3b3d5177c23a0b3299db649db4900f446763f68e3d9
```

SHA-256 of the corresponding prompt:

```text
70ef10895e5d2c7ceb8ee74ff7c3d4302f1a13ebafdb11f5236fec7e7286b8cb
```

The hashes were used as part of the integrity checks for the transferred test data.

---

## 9. CPU-Only Decode Verification

The Decode phase on the M6 did not use a GPU for model inference.

For the 16K run:

```text
CPU-only = true
```

An existing protected llama.cpp RPC process on the M6 was also checked to verify that it had not been replaced or restarted as part of the PD test.

```text
PID       = 10992
unchanged = true
```

Detected error matches:

```text
0
```

---

## 10. 16K Output-Quality Condition

The 16K test successfully completed the PD process and generated exactly 2,048 tokens.

However, the entire 2,048-token generation budget was consumed by English-language `<think>` output, and generation did not reach the requested Japanese final answer.

For this reason, the experiment separates:

* **PD mechanism success**
* **output-quality success**

The following PD conditions were satisfied:

* state transfer succeeded
* Restore succeeded
* restored cache was reused
* full Prompt Prefill was avoided on the Decode machine
* CPU-only Decode succeeded
* exactly 2,048 tokens were generated
* no matching error was detected

The Japanese-output condition was not satisfied.

Overall classification:

```text
PD SUCCESS / OUTPUT CONDITION PARTIAL FAIL
```

The 4K test successfully produced Japanese final output.

---

## 11. Difference from Normal RPC Distributed Inference

Normal RPC distributed inference:

```text
GPU A
  +
GPU B
  +
CPU/RAM
   |
   v
Prefill
   |
   v
Decode
```

This experimental PD setup:

```text
GPU A + GPU B + RAM
          |
          v
       Prefill
          |
          v
       STATE
          |
     network transfer
          |
          v
      CPU + RAM
          |
          v
       Decode
```

With normal RPC distributed inference, the same distributed inference configuration continues from Prefill into Decode.

In this experiment, the Prefill state is detached from that configuration and transferred to another machine.

As a result, the compute resources used for Prefill can, in principle, be released from the long-running Decode phase of that request.

---

## 12. What Was Demonstrated

The experiment confirmed that a slot state produced after Prefill using a llama.cpp RPC distributed configuration could be:

1. saved,
2. transferred to another physical machine,
3. restored there,
4. reused as Prompt cache,
5. and continued with CPU/RAM-only Decode,

without performing a full Prompt Prefill again on the Decode machine.

This was confirmed at both 4K and 16K Prompt lengths.

The most important 16K counters were:

```text
n_restored = 16000
cache_n    = 15999
prompt_n   = 1
```

and the Decode machine subsequently completed:

```text
predicted_n = 2048
exact_2048  = true
```

---

## 13. Current Position of This Repository

This is **not** a production-ready LLM serving system.

It is also not intended as a replacement for llama.cpp's own PD implementation.

At this stage, it should be considered:

> An experimental externally orchestrated heterogeneous Disaggregated Prefill/Decode PoC using existing llama.cpp RPC distributed inference and slot-state functionality.

The main result is the practical demonstration of:

```text
distributed RPC Prefill
        |
        v
slot-state transfer
        |
        v
separate CPU/RAM-only Decode
```

across physically separate machines.

---

## 14. Reproducibility Status

**Work in progress**

Version 0.1 prioritizes publication of the experimental architecture and measured results.

The following reproduction information will be added in subsequent revisions after the original experimental data has been organized and verified:

* exact llama.cpp commit / build
* operating systems
* Prefill-side startup command
* RPC-server startup command
* Decode-side startup command
* exact model
* quantization
* context size
* batch / ubatch and other relevant parameters
* Prompt generation procedure
* slot-state save procedure
* state transfer procedure
* Restore procedure
* cache-reuse validation procedure
* raw benchmark JSON
* orchestration scripts

Until these items are published, this repository should be treated as an **experimental report**, not as a complete reproduction package.

---

## 15. Planned Updates

The repository is expected to evolve approximately as follows:

```text
v0.1  Experimental report
v0.2  Environment / build / commands
v0.3  Raw benchmark data
v0.4  PD orchestration scripts
v1.0  Reproducible PoC
```

The immediate priority is to preserve and publish the measured experimental result.

Reproduction material will be added incrementally.

---

## 16. Security Note

This experiment uses llama.cpp RPC.

The setup is intended for use only in a trusted environment.

Do not expose llama.cpp RPC services directly to untrusted or public networks.

Users attempting to reproduce the experiment should review the official llama.cpp security guidance before running RPC services.

---

## 17. Related llama.cpp Development

Relevant upstream llama.cpp work includes:

* [Issue #21266 — server: disaggregated prefill/decode support](https://github.com/ggml-org/llama.cpp/issues/21266)
* [PR #27058 — disaggregated prompt prefill over RPC](https://github.com/ggml-org/llama.cpp/pull/27058)
* llama-server slot-state save / restore functionality

This experiment does not use PR #27058.

It is an independent external orchestration experiment built from existing llama.cpp functionality.

---

## Conclusion

The following workflow was successfully demonstrated on real hardware:

```text
Distributed RPC Prefill
        |
        v
slot-state save
        |
        v
network transfer
        |
        v
restore on another machine
        |
        v
cache reuse
        |
        v
CPU-only Decode
```

For the 16K test, 15,999 of 16,000 Prompt tokens were reused from the restored cache, and the Decode machine completed exactly 2,048 generated tokens without performing a full Prompt Prefill.

Under the tested configuration, including measured state-transfer overhead, total processing time was reduced relative to the normal RPC configuration by:

* **30.19% at 4K**
* **16.62% at 16K**

The current conclusion is:

> **A slot state produced by distributed llama.cpp RPC Prefill can be transferred to a separate machine and used to continue CPU/RAM-only Decode without re-running the full Prompt Prefill, at least under the tested 4K and 16K configurations.**
