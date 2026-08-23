# Script map

| Script | Node | Purpose |
|---|---|---|
| `sub-windows/start-rpc.ps1` | SUB | Start one configured CUDA0 RPC server |
| `main/start-prefill.ps1` | Main | Start distributed Prefill server |
| `main/prefill-save.ps1` | Main | Evaluate exact Prompt and save slot 0 |
| `m6/start-decode.ps1` | M6 | Start CPU-only Decode server |
| `m6/receive-state.ps1` | M6 | Receive and verify one state file |
| `main/send-state.ps1` | Main | Send one verified state file |
| `m6/restore-decode.ps1` | M6 | Restore and run streaming 2,048-token Decode |
| `stop-managed-process.ps1` | Any | Stop only a saved PID after path verification |

All scripts use strict error handling and require an explicitly confirmed `config/config.json`. They do not discover LAN hosts and do not automatically retry a failed test session.

Parser validation was performed with Windows PowerShell 5.1. The sanitized public scripts were not rerun against the original three physical nodes after path/IP parameterization; this is recorded as a limitation rather than being inferred from the private scripts.
