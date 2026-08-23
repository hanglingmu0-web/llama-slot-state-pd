Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

if (-not ('System.Net.Http.HttpClientHandler' -as [type])) {
    Add-Type -AssemblyName System.Net.Http
}

function Get-PdConfig {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Config not found: $full" }
    $config = Get-Content -LiteralPath $full -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not [bool]$config.confirmed) { throw 'Set confirmed=true only after reviewing every config value.' }
    return $config
}

function Get-PdCase {
    param([Parameter(Mandatory)][object]$Config,[Parameter(Mandatory)][ValidateSet('4k','16k')][string]$Case)
    $value = $Config.cases.$Case
    if ($null -eq $value) { throw "Case missing from config: $Case" }
    return $value
}

function Ensure-PdDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path) }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a normal directory: $Path"
    }
}

function Write-PdText {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    Ensure-PdDirectory -Path $parent
    [IO.File]::WriteAllText($Path,$Text,$script:Utf8NoBom)
}

function Write-PdJson {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    Write-PdText -Path $Path -Text (($Value | ConvertTo-Json -Depth 40) + "`n")
}

function Get-PdSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PdFileIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int64]$Bytes,
        [Parameter(Mandatory)][string]$Sha256
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point rejected: $Path" }
    if ([int64]$item.Length -ne $Bytes) { throw "Byte-size mismatch: $Path" }
    $actual = Get-PdSha256 -Path $Path
    if ($actual -ne $Sha256.ToLowerInvariant()) { throw "SHA-256 mismatch: $Path" }
    return [pscustomobject]@{ path=$item.FullName; bytes=[int64]$item.Length; sha256=$actual }
}

function Assert-PdModel {
    param([Parameter(Mandatory)][object]$Config,[Parameter(Mandatory)][ValidateSet('main','m6')][string]$Node)
    $path = [string]$Config.$Node.model_path
    return Assert-PdFileIdentity -Path $path -Bytes ([int64]$Config.model.bytes) -Sha256 ([string]$Config.model.sha256)
}

function Get-PdPrompt {
    param([Parameter(Mandatory)][object]$Config,[Parameter(Mandatory)][ValidateSet('4k','16k')][string]$Case)
    $spec = Get-PdCase -Config $Config -Case $Case
    $path = Join-Path $script:RepoRoot ([string]$spec.prompt_relative_path)
    $identity = Assert-PdFileIdentity -Path $path -Bytes ([int64]$spec.prompt_bytes) -Sha256 ([string]$spec.prompt_sha256)
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { throw "Prompt has a UTF-8 BOM: $path" }
    $strict = [Text.UTF8Encoding]::new($false,$true)
    return [pscustomobject]@{ identity=$identity; text=$strict.GetString($bytes); spec=$spec }
}

function ConvertTo-PdArgumentString {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $quoted = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') { '"' + ($argument -replace '"','\"') + '"' } else { $argument }
    }
    return $quoted -join ' '
}

function Wait-PdHealth {
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][int]$Pid,[int]$TimeoutSeconds=1800)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Get-Process -Id $Pid -ErrorAction SilentlyContinue)) { throw "Managed server exited before readiness: PID $Pid" }
        try {
            $health = Invoke-RestMethod -Method Get -Uri "$Uri/health" -TimeoutSec 5
            if ([string]$health.status -eq 'ok') { return $health }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    throw "Health timeout: $Uri"
}

function Assert-PdPidPath {
    param([Parameter(Mandatory)][string]$PidPath,[Parameter(Mandatory)][string]$ExpectedExecutable)
    if (-not (Test-Path -LiteralPath $PidPath -PathType Leaf)) { throw "PID file missing: $PidPath" }
    $id = [int]([IO.File]::ReadAllText($PidPath).Trim())
    $process = Get-Process -Id $id -ErrorAction Stop
    if (-not [string]::Equals([IO.Path]::GetFullPath($process.Path),[IO.Path]::GetFullPath($ExpectedExecutable),[StringComparison]::OrdinalIgnoreCase)) {
        throw "PID $id is not the expected executable: $($process.Path)"
    }
    return $process
}

function Assert-PdCpuOnlyProcess {
    param([Parameter(Mandatory)][Diagnostics.Process]$Process)
    $bad = @($Process.Modules | Where-Object { $_.ModuleName -match '(?i)cuda|cublas|ggml-rpc' })
    if ($bad.Count -gt 0) { throw "Decode process loaded a prohibited module: $($bad[0].ModuleName)" }
}

function Read-PdExact {
    param([Parameter(Mandatory)][IO.Stream]$Stream,[Parameter(Mandatory)][int]$Count)
    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer,$offset,$Count-$offset)
        if ($read -le 0) { throw "Peer closed with $($Count-$offset) bytes remaining." }
        $offset += $read
    }
    return ,$buffer
}

function Write-PdJsonFrame {
    param([Parameter(Mandatory)][IO.Stream]$Stream,[Parameter(Mandatory)][object]$Value)
    $bytes = $script:Utf8NoBom.GetBytes(($Value | ConvertTo-Json -Compress -Depth 30))
    if ($bytes.Length -le 0 -or $bytes.Length -gt 65536) { throw "Invalid JSON frame size: $($bytes.Length)" }
    $length = [BitConverter]::GetBytes([int]$bytes.Length)
    $Stream.Write($length,0,4)
    $Stream.Write($bytes,0,$bytes.Length)
    $Stream.Flush()
}

function Read-PdJsonFrame {
    param([Parameter(Mandatory)][IO.Stream]$Stream)
    $lengthBytes = Read-PdExact -Stream $Stream -Count 4
    $length = [BitConverter]::ToInt32($lengthBytes,0)
    if ($length -le 0 -or $length -gt 65536) { throw "Invalid JSON frame length: $length" }
    $bytes = Read-PdExact -Stream $Stream -Count $length
    return ($script:Utf8NoBom.GetString($bytes) | ConvertFrom-Json)
}

function Invoke-PdStreamingCompletion {
    param([Parameter(Mandatory)][string]$Uri,[Parameter(Mandatory)][object]$Body,[int]$TimeoutSeconds=7200)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post,$Uri)
    $request.Content = [Net.Http.StringContent]::new(($Body|ConvertTo-Json -Compress -Depth 20),$script:Utf8NoBom,'application/json')
    $started = [DateTime]::UtcNow
    $firstToken = $null
    $content = [Text.StringBuilder]::new()
    $final = $null
    $response = $null
    $stream = $null
    $reader = $null
    try {
        $response = $client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "Completion HTTP $([int]$response.StatusCode): $($response.Content.ReadAsStringAsync().GetAwaiter().GetResult())" }
        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $reader = [IO.StreamReader]::new($stream,$script:Utf8NoBom,$true,65536,$true)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line) -or -not $line.StartsWith('data: ')) { continue }
            $data = $line.Substring(6)
            if ($data -eq '[DONE]') { break }
            $item = $data | ConvertFrom-Json
            $final = $item
            if ($null -ne $item.content -and ([string]$item.content).Length -gt 0) {
                if ($null -eq $firstToken) { $firstToken = [DateTime]::UtcNow }
                [void]$content.Append([string]$item.content)
            }
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose();$client.Dispose();$handler.Dispose()
    }
    $ended = [DateTime]::UtcNow
    if ($null -eq $firstToken -or $null -eq $final) { throw 'Streaming response did not contain token content and final timings.' }
    return [pscustomobject]@{
        started_utc=$started.ToString('o');first_token_utc=$firstToken.ToString('o');ended_utc=$ended.ToString('o')
        ttft_ms=[math]::Round(($firstToken-$started).TotalMilliseconds,3)
        wall_ms=[math]::Round(($ended-$started).TotalMilliseconds,3)
        content=$content.ToString();final=$final
    }
}
