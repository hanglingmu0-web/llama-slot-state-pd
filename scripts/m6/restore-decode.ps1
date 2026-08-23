[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('4k','16k')][string]$Case
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')

$config=Get-PdConfig -Path $ConfigPath;$prompt=Get-PdPrompt -Config $config -Case $Case
$exe=[string]$config.m6.llama_server;$process=Assert-PdPidPath -PidPath (Join-Path ([string]$config.m6.runtime_root) 'decode.pid') -ExpectedExecutable $exe
Assert-PdCpuOnlyProcess -Process $process;$base="http://127.0.0.1:$($config.network.decode_http_port)";Wait-PdHealth -Uri $base -Pid $process.Id -TimeoutSeconds 30|Out-Null
$receivePath=Join-Path ([string]$config.m6.outputs_root) "state-receive-$Case.json";if(-not(Test-Path -LiteralPath $receivePath)){throw "Receive evidence missing: $receivePath"}
$receive=Get-Content -LiteralPath $receivePath -Raw -Encoding UTF8|ConvertFrom-Json;$statePath=Join-Path ([string]$config.m6.slots_root) ([string]$receive.filename)
[void](Assert-PdFileIdentity -Path $statePath -Bytes ([int64]$receive.length) -Sha256 ([string]$receive.sha256))
$restoreStarted=[DateTime]::UtcNow;$restore=Invoke-RestMethod -Method Post -Uri "$base/slots/0?action=restore" -ContentType 'application/json; charset=utf-8' -Body (@{filename=[string]$receive.filename}|ConvertTo-Json -Compress) -TimeoutSec 1800;$restoreEnded=[DateTime]::UtcNow
if([int64]$restore.n_restored-ne[int64]$receive.n_saved-or[int64]$restore.n_read-ne[int64]$receive.n_written){throw 'Restore counters do not match save/transfer evidence.'}
$body=[ordered]@{prompt=$prompt.text;n_predict=[int]$config.decode.n_predict;cache_prompt=$true;id_slot=0;temperature=0;seed=1234;stream=$true;timings_per_token=$true}
$decode=Invoke-PdStreamingCompletion -Uri "$base/completion" -Body $body -TimeoutSeconds 7200;$timings=$decode.final.timings
if([int]$timings.cache_n-lt([int64]$receive.n_saved-2)-or[int]$timings.prompt_n-gt2){throw "Restored cache was not reused: cache_n=$($timings.cache_n) prompt_n=$($timings.prompt_n)"}
if([int]$timings.predicted_n-ne[int]$config.decode.n_predict){throw "Decode did not complete the configured token count: $($timings.predicted_n)"}
$process.Refresh();Assert-PdCpuOnlyProcess -Process $process
$result=[ordered]@{case=$Case;model_sha256=$config.model.sha256;prompt_tokens=$prompt.spec.prompt_tokens;prompt_sha256=$prompt.identity.sha256;state_bytes=[int64]$receive.length;state_sha256=$receive.sha256;restore=[ordered]@{n_restored=[int64]$restore.n_restored;n_read=[int64]$restore.n_read;restore_ms=[double]$restore.timings.restore_ms;wall_ms=[math]::Round(($restoreEnded-$restoreStarted).TotalMilliseconds,3)};decode=[ordered]@{cache_n=[int]$timings.cache_n;prompt_n=[int]$timings.prompt_n;predicted_n=[int]$timings.predicted_n;predicted_ms=[double]$timings.predicted_ms;predicted_per_second=[double]$timings.predicted_per_second;ttft_ms=$decode.ttft_ms;wall_ms=$decode.wall_ms;output=$decode.content};cpu_only=$true;completed_utc=[DateTime]::UtcNow.ToString('o')}
Write-PdJson -Path (Join-Path ([string]$config.m6.outputs_root) "restore-decode-$Case.json") -Value $result;Write-PdText -Path (Join-Path ([string]$config.m6.outputs_root) "generated-$Case.txt") -Text $decode.content;$result|ConvertTo-Json -Depth 30
