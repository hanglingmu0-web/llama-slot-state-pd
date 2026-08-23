# Prompt artifacts

The files in this directory are the exact UTF-8, BOM-free Prompt byte sequences used for the published 4K and 16K cases.

| File | Bytes | llama.cpp tokens | SHA-256 |
|---|---:|---:|---|
| `records-4k.txt` | 14,235 | 4,000 | `eb62156bf168ed142135fd7916c723c8caa4a6f010c474eb6fb8e37dbd011e4d` |
| `records-16k.txt` | 56,567 | 16,000 | `70ef10895e5d2c7ceb8ee74ff7c3d4302f1a13ebafdb11f5236fec7e7286b8cb` |

Token counts were measured with the selected llama.cpp build and model tokenizer. The reproduction scripts verify bytes and SHA before use. Prefill and Decode receive the same file contents; the M6 does not regenerate a chat template.

The prompts are synthetic numbered records and are included under the repository license.
