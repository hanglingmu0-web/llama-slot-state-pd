[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('4k','16k')][string]$Case
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')

$config = Get-PdConfig -Path $ConfigPath
$prompt = Get-PdPrompt -Config $config -Case $Case
$exe = [string]$config.main.llama_server
$pidPath = Join-Path ([string]$config.main.runtime_root) 'prefill.pid'
$process = Assert-PdPidPath -PidPath $pidPath -ExpectedExecutable $exe
$base = "http://127.0.0.1:$($config.network.prefill_http_port)"
Wait-PdHealth -Uri $base -Pid $process.Id -TimeoutSeconds 30|Out-Null
$body = [ordered]@{prompt=$prompt.text;n_predict=0;cache_prompt=$true;id_slot=0;temperature=0;seed=1234}
$started = [DateTime]::UtcNow
$prefill = Invoke-RestMethod -Method Post -Uri "$base/completion" -ContentType 'application/json; charset=utf-8' -Body ($body|ConvertTo-Json -Compress -Depth 10) -TimeoutSec 3600
$prefillEnded = [DateTime]::UtcNow
$stateFilename = [string]$prompt.spec.state_filename
$save = Invoke-RestMethod -Method Post -Uri "$base/slots/0?action=save" -ContentType 'application/json; charset=utf-8' -Body (@{filename=$stateFilename}|ConvertTo-Json -Compress) -TimeoutSec 1800
$statePath = Join-Path ([string]$config.main.slots_root) $stateFilename
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw "State file missing after save: $statePath" }
$state = Get-Item -LiteralPath $statePath -Force
if ([int64]$save.n_saved -le 0 -or [int64]$save.n_written -ne [int64]$state.Length) { throw 'Slot save counters do not match the state file.' }
$result = [ordered]@{
    case=$Case;prompt_tokens=[int]$prompt.spec.prompt_tokens;prompt_bytes=[int64]$prompt.identity.bytes;prompt_sha256=$prompt.identity.sha256
    request=$body;prefill_response=$prefill;prefill_wall_ms=[math]::Round(($prefillEnded-$started).TotalMilliseconds,3)
    slot_file=$stateFilename;n_saved=[int64]$save.n_saved;n_written=[int64]$save.n_written;save_ms=[double]$save.timings.save_ms
    state_file_bytes=[int64]$state.Length;state_file_sha256=(Get-PdSha256 -Path $statePath);completed_utc=[DateTime]::UtcNow.ToString('o')
}
$out = Join-Path ([string]$config.main.outputs_root) "prefill-save-$Case.json"
Write-PdJson -Path $out -Value $result
$result|ConvertTo-Json -Depth 30
