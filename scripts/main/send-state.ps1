[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('4k','16k')][string]$Case
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')

$config = Get-PdConfig -Path $ConfigPath
$caseSpec = Get-PdCase -Config $config -Case $Case
$evidencePath = Join-Path ([string]$config.main.outputs_root) "prefill-save-$Case.json"
if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) { throw "Prefill/save evidence missing: $evidencePath" }
$evidence = Get-Content -LiteralPath $evidencePath -Raw -Encoding UTF8|ConvertFrom-Json
$statePath = Join-Path ([string]$config.main.slots_root) ([string]$evidence.slot_file)
$identity = Assert-PdFileIdentity -Path $statePath -Bytes ([int64]$evidence.n_written) -Sha256 ([string]$evidence.state_file_sha256)
$header = [ordered]@{
    protocol='llama-pd-slot-single-file-v1';source_ip=[string]$config.network.main_ip;destination_ip=[string]$config.network.m6_ip
    filename=[string]$caseSpec.state_filename;length=[int64]$identity.bytes;sha256=$identity.sha256;case=$Case
    model_sha256=[string]$config.model.sha256;llama_build=[int]$config.llama_cpp.build;llama_commit=[string]$config.llama_cpp.commit
    n_saved=[int64]$evidence.n_saved;n_written=[int64]$evidence.n_written;prompt_sha256=[string]$caseSpec.prompt_sha256
}
$client=[Net.Sockets.TcpClient]::new()
$stream=$null
try{
    $connect=$client.ConnectAsync([string]$config.network.m6_ip,[int]$config.network.state_transfer_port)
    if(-not $connect.Wait(5000)-or-not $client.Connected){throw 'M6 state receiver connection timed out; no retry was made.'}
    $client.NoDelay=$true;$client.SendTimeout=30000;$client.ReceiveTimeout=1800000
    $stream=$client.GetStream();Write-PdJsonFrame -Stream $stream -Value $header
    $started=[DateTime]::UtcNow
    $file=[IO.File]::Open($statePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{$buffer=[byte[]]::new(1MB);$sent=[int64]0;while(($read=$file.Read($buffer,0,$buffer.Length))-gt 0){$stream.Write($buffer,0,$read);$sent+=$read};$stream.Flush()}finally{$file.Dispose()}
    $ended=[DateTime]::UtcNow;$ack=Read-PdJsonFrame -Stream $stream
    if(-not[bool]$ack.ok-or[int64]$ack.length-ne$identity.bytes-or[string]$ack.sha256-ne$identity.sha256){throw "Receiver acknowledgement mismatch: $($ack|ConvertTo-Json -Compress)"}
    $result=[ordered]@{case=$Case;bytes=$sent;sha256=$identity.sha256;started_utc=$started.ToString('o');ended_utc=$ended.ToString('o');seconds=[math]::Round(($ended-$started).TotalSeconds,6);ack=$ack}
    Write-PdJson -Path (Join-Path ([string]$config.main.outputs_root) "state-transfer-$Case.json") -Value $result
    $result|ConvertTo-Json -Depth 20
}finally{if($null-ne$stream){$stream.Dispose()};$client.Dispose()}
