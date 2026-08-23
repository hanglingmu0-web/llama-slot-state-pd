[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateSet('main','sub','m6')][string]$Role
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$config = Get-PdConfig -Path $ConfigPath
switch ($Role) {
    'main' { $root=[string]$config.main.runtime_root;$exe=[string]$config.main.llama_server;$name='prefill' }
    'sub'  { $root=[string]$config.sub.runtime_root;$exe=[string]$config.sub.rpc_server;$name='rpc' }
    'm6'   { $root=[string]$config.m6.runtime_root;$exe=[string]$config.m6.llama_server;$name='decode' }
}
$pidPath = Join-Path $root "$name.pid"
$process = Assert-PdPidPath -PidPath $pidPath -ExpectedExecutable $exe
$id = $process.Id
[void]$process.CloseMainWindow()
if (-not $process.WaitForExit(10000)) {
    $again = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($null -ne $again) { Stop-Process -Id $id -Force -ErrorAction Stop }
}
if (Get-Process -Id $id -ErrorAction SilentlyContinue) { throw "Managed PID did not stop: $id" }
Remove-Item -LiteralPath $pidPath -Force
[pscustomobject]@{ role=$Role;pid=$id;stopped=$true;executable=$exe } | ConvertTo-Json -Compress
