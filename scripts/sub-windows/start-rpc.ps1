[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')

$config = Get-PdConfig -Path $ConfigPath
$exe = [string]$config.sub.rpc_server
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "RPC executable missing: $exe" }
Ensure-PdDirectory -Path ([string]$config.sub.runtime_root)
Ensure-PdDirectory -Path ([string]$config.sub.logs_root)
$pidPath = Join-Path ([string]$config.sub.runtime_root) 'rpc.pid'
if (Test-Path -LiteralPath $pidPath) { throw "PID file already exists; inspect it manually: $pidPath" }
$stdout = Join-Path ([string]$config.sub.logs_root) 'rpc.out.log'
$stderr = Join-Path ([string]$config.sub.logs_root) 'rpc.err.log'
$arguments = @('--host',[string]$config.network.sub_ip,'--port',[string]$config.network.rpc_port,'--device','CUDA0')
$process = Start-Process -FilePath $exe -ArgumentList (ConvertTo-PdArgumentString -Arguments $arguments) -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
Write-PdText -Path $pidPath -Text ([string]$process.Id)
Start-Sleep -Seconds 2
if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) { throw "RPC process exited during startup. Inspect $stderr" }
[pscustomobject]@{pid=$process.Id;endpoint="$($config.network.sub_ip):$($config.network.rpc_port)";device='CUDA0';stdout=$stdout;stderr=$stderr}|ConvertTo-Json -Compress
