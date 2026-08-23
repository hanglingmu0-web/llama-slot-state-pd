# Result artifacts

These JSON files were derived from the preserved experiment outputs. Numerical values, counters, timestamps, generated text, and error lists were retained. Environment-specific strings were mechanically replaced as follows:

```text
Main workspace paths -> ${MAIN_PD_ROOT}
M6 workspace paths   -> ${M6_PD_ROOT}
Model paths          -> ${MODEL_ROOT}
Main/SUB/M6 LAN IPs  -> ${MAIN_IP} / ${SUB_IP} / ${M6_IP}
```

The replacement does not alter numerical benchmark values.

`results/16k/m6-restore-decode.json` is the normalized successful exact-2,048 result extracted from the returned M6 final frame. The misleading Main-side failure wrapper caused by an unexpected protocol-frame order is not published as the canonical result.

Both `pd_component_total_s` values in `summary.*` are sums of measured components, not a continuous client wall clock. See each case's `run-manifest.json` for provenance.

The state binaries and GGUF model are intentionally omitted. Their byte sizes and SHA-256 values are retained in the JSON/manifests.
