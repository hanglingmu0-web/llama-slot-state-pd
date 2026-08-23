[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')

$config = Get-PdConfig -Path $ConfigPath
$model = Assert-PdModel -Config $config -Node m6
$exe = [string]$config.m6.llama_server
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "llama-server missing: $exe" }
foreach($directory in @([string]$config.m6.runtime_root,[string]$config.m6.slots_root,[string]$config.m6.logs_root,[string]$config.m6.outputs_root)){Ensure-PdDirectory -Path $directory}
$pidPath = Join-Path ([string]$config.m6.runtime_root) 'decode.pid'
if (Test-Path -LiteralPath $pidPath) { throw "PID file already exists; inspect it manually: $pidPath" }
$stdout = Join-Path ([string]$config.m6.logs_root) 'decode.out.log'
$stderr = Join-Path ([string]$config.m6.logs_root) 'decode.err.log'
$log = Join-Path ([string]$config.m6.logs_root) 'decode.log'
$arguments = @(
    '-m',$model.path,'--n-gpu-layers','0','--no-kv-offload','--cache-ram','0','--parallel','1',
    '--slot-save-path',[string]$config.m6.slots_root,'--slots','--ctx-size',[string]$config.decode.context_size,
    '--cache-type-k',[string]$config.decode.cache_type_k,'--cache-type-v',[string]$config.decode.cache_type_v,
    '--flash-attn','off','--metrics','--host','127.0.0.1','--port',[string]$config.network.decode_http_port,
    '--log-file',$log,'--log-verbosity','4','--load-mode','none'
)
$command = '"{0}" {1}' -f $exe,(ConvertTo-PdArgumentString -Arguments $arguments)
Write-PdText -Path (Join-Path ([string]$config.m6.logs_root) 'decode-command.txt') -Text ($command+"`n")
$process = Start-Process -FilePath $exe -ArgumentList (ConvertTo-PdArgumentString -Arguments $arguments) -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
Write-PdText -Path $pidPath -Text ([string]$process.Id)
Wait-PdHealth -Uri "http://127.0.0.1:$($config.network.decode_http_port)" -Pid $process.Id -TimeoutSeconds 2400|Out-Null
$process.Refresh();Assert-PdCpuOnlyProcess -Process $process
[pscustomobject]@{pid=$process.Id;model=$model;command=$command;health='ok';cpu_only=$true;log=$log}|ConvertTo-Json -Depth 8
