[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConfigPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'common.ps1')

$config = Get-PdConfig -Path $ConfigPath
$model = Assert-PdModel -Config $config -Node main
$exe = [string]$config.main.llama_server
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "llama-server missing: $exe" }
foreach($directory in @([string]$config.main.runtime_root,[string]$config.main.slots_root,[string]$config.main.logs_root,[string]$config.main.outputs_root)){Ensure-PdDirectory -Path $directory}
$pidPath = Join-Path ([string]$config.main.runtime_root) 'prefill.pid'
if (Test-Path -LiteralPath $pidPath) { throw "PID file already exists; inspect it manually: $pidPath" }
$stdout = Join-Path ([string]$config.main.logs_root) 'prefill.out.log'
$stderr = Join-Path ([string]$config.main.logs_root) 'prefill.err.log'
$log = Join-Path ([string]$config.main.logs_root) 'prefill.log'
$arguments = @(
    '-m',$model.path,
    '--rpc',"$($config.network.sub_ip):$($config.network.rpc_port)",
    '--split-mode','layer','--tensor-split',[string]$config.prefill.tensor_split,
    '--n-gpu-layers',[string]$config.prefill.n_gpu_layers,'--fit','off',
    '--no-kv-offload','--cache-ram','0','--parallel','1',
    '--slot-save-path',[string]$config.main.slots_root,'--slots',
    '--ctx-size',[string]$config.prefill.context_size,
    '--cache-type-k',[string]$config.prefill.cache_type_k,
    '--cache-type-v',[string]$config.prefill.cache_type_v,
    '--flash-attn','off','--metrics','--host','127.0.0.1',
    '--port',[string]$config.network.prefill_http_port,
    '--log-file',$log,'--log-verbosity','4','--load-mode','none'
)
$command = '"{0}" {1}' -f $exe,(ConvertTo-PdArgumentString -Arguments $arguments)
Write-PdText -Path (Join-Path ([string]$config.main.logs_root) 'prefill-command.txt') -Text ($command+"`n")
$process = Start-Process -FilePath $exe -ArgumentList (ConvertTo-PdArgumentString -Arguments $arguments) -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
Write-PdText -Path $pidPath -Text ([string]$process.Id)
Wait-PdHealth -Uri "http://127.0.0.1:$($config.network.prefill_http_port)" -Pid $process.Id -TimeoutSeconds 2400|Out-Null
[pscustomobject]@{pid=$process.Id;model=$model;command=$command;health='ok';log=$log}|ConvertTo-Json -Depth 8
