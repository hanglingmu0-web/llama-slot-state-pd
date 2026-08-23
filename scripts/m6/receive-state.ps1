[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('4k','16k')][string]$Case,
    [ValidateRange(1,60)][int]$AcceptTimeoutMinutes=15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')

$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run receiver in an elevated PowerShell.'}
$config=Get-PdConfig -Path $ConfigPath;$spec=Get-PdCase -Config $config -Case $Case
foreach($directory in @([string]$config.m6.slots_root,[string]$config.m6.outputs_root)){Ensure-PdDirectory -Path $directory}
$finalPath=Join-Path ([string]$config.m6.slots_root) ([string]$spec.state_filename);$partialPath=$finalPath+'.partial'
if((Test-Path -LiteralPath $finalPath)-or(Test-Path -LiteralPath $partialPath)){throw 'Destination state or partial file already exists.'}
$rule="llama-slot-state-pd-$Case-$($config.network.state_transfer_port)"
if(Get-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue){throw "Firewall rule already exists: $rule"}
$listener=$null;$client=$null;$stream=$null;$ruleCreated=$false
try{
    New-NetFirewallRule -Name $rule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalAddress ([string]$config.network.m6_ip) -LocalPort ([int]$config.network.state_transfer_port) -RemoteAddress ([string]$config.network.main_ip)|Out-Null;$ruleCreated=$true
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse([string]$config.network.m6_ip),[int]$config.network.state_transfer_port);$listener.Start(1)
    $accept=$listener.AcceptTcpClientAsync();if(-not $accept.Wait([TimeSpan]::FromMinutes($AcceptTimeoutMinutes))){throw 'State receiver accept timed out; no retry was made.'}
    $client=$accept.Result;$remote=([Net.IPEndPoint]$client.Client.RemoteEndPoint).Address.IPAddressToString
    if($remote-ne[string]$config.network.main_ip){throw "Rejected source IP: $remote"}
    $client.NoDelay=$true;$client.ReceiveTimeout=30000;$client.SendTimeout=30000;$stream=$client.GetStream();$header=Read-PdJsonFrame -Stream $stream
    if([string]$header.protocol-ne'llama-pd-slot-single-file-v1'){throw 'Protocol mismatch.'}
    if([string]$header.source_ip-ne[string]$config.network.main_ip-or[string]$header.destination_ip-ne[string]$config.network.m6_ip){throw 'Header IP mismatch.'}
    if([string]$header.case-ne$Case-or[string]$header.filename-ne[string]$spec.state_filename){throw 'Case/state filename mismatch.'}
    if([int]$header.llama_build-ne[int]$config.llama_cpp.build-or[string]$header.llama_commit-ne[string]$config.llama_cpp.commit){throw 'Build/commit mismatch.'}
    if([string]$header.model_sha256-ne[string]$config.model.sha256-or[string]$header.prompt_sha256-ne[string]$spec.prompt_sha256){throw 'Model/Prompt identity mismatch.'}
    if([int64]$header.length-le0-or[int64]$header.length-gt5GB-or[int64]$header.length-ne[int64]$header.n_written){throw 'State length rejected.'}
    if([string]$header.sha256-notmatch'^[0-9a-f]{64}$'){throw 'State SHA-256 rejected.'}
    $started=[DateTime]::UtcNow;$file=[IO.File]::Open($partialPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$buffer=[byte[]]::new(1MB);$received=[int64]0;while($received-lt[int64]$header.length){$wanted=[int][math]::Min($buffer.Length,[int64]$header.length-$received);$read=$stream.Read($buffer,0,$wanted);if($read-le0){throw "Sender closed at $received bytes."};$file.Write($buffer,0,$read);$received+=$read};$file.Flush($true)}finally{$file.Dispose()}
    $ended=[DateTime]::UtcNow;$actual=Get-PdSha256 -Path $partialPath
    if((Get-Item -LiteralPath $partialPath).Length-ne[int64]$header.length-or$actual-ne[string]$header.sha256){throw 'Received state byte/SHA mismatch.'}
    Move-Item -LiteralPath $partialPath -Destination $finalPath
    $result=[ordered]@{ok=$true;case=$Case;filename=$spec.state_filename;length=[int64]$header.length;sha256=$actual;n_saved=[int64]$header.n_saved;n_written=[int64]$header.n_written;prompt_sha256=$header.prompt_sha256;started_utc=$started.ToString('o');ended_utc=$ended.ToString('o');receive_seconds=[math]::Round(($ended-$started).TotalSeconds,6)}
    Write-PdJson -Path (Join-Path ([string]$config.m6.outputs_root) "state-receive-$Case.json") -Value $result;Write-PdJsonFrame -Stream $stream -Value $result;$result|ConvertTo-Json -Depth 20
}catch{if($null-ne$stream-and$stream.CanWrite){try{Write-PdJsonFrame -Stream $stream -Value @{ok=$false;error=$_.Exception.Message}}catch{}};if(Test-Path -LiteralPath $partialPath){Remove-Item -LiteralPath $partialPath -Force};throw}finally{if($null-ne$stream){$stream.Dispose()};if($null-ne$client){$client.Dispose()};if($null-ne$listener){$listener.Stop()};if($ruleCreated){Remove-NetFirewallRule -Name $rule -ErrorAction Stop}}
