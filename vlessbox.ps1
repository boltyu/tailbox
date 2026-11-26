<#
.SYNOPSIS
    VlessBox Service Controller (sing-box TUN + native VLESS/Reality outbound)
.DESCRIPTION
    Manages a standalone sing-box instance that connects directly to a VLESS+Reality VPS.
    Independent from tailbox.ps1 (which uses Tailscale + SOCKS5).
    Commands: start, stop, restart, status, import, check, log, install-path, help.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "restart", "status", "log", "logs", "check", "import", "install-path", "help", "", $null)]
    [string]$Action = "status",

    [Parameter(Position = 1)]
    [string]$Target = ""
)

# --- Configuration & Paths ---
$scriptDir = $PSScriptRoot
$configPath = Join-Path $scriptDir "config.vless.json"
$logDir = Join-Path $scriptDir "logs"
$singBoxLog = Join-Path $logDir "vlessbox.log"
$singBoxErrLog = Join-Path $logDir "vlessbox.err.log"
$vlessPidFile = Join-Path $scriptDir ".vlessbox.pid"
$tailboxSingBoxPidFile = Join-Path $scriptDir ".singbox.pid"
$mixedPort = 10808

# --- Helper Functions ---

function Resolve-SingBoxExecutable {
    $candidates = @(Get-ChildItem -Path $scriptDir -Directory -Filter "sing-box-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "sing-box.exe" } |
        Where-Object { Test-Path $_ })
    if ($candidates.Count -gt 0) { return $candidates[0] }

    $local = Join-Path $scriptDir "sing-box.exe"
    if (Test-Path $local) { return $local }

    $cmd = Get-Command "sing-box.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

$singBoxExe = Resolve-SingBoxExecutable
$singBoxDir = if ($singBoxExe) { Split-Path $singBoxExe -Parent } else { $scriptDir }

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    param([string]$SubAction, [string]$SubTarget)
    if (-not (Test-IsAdmin)) {
        Write-Host "Administrator privileges required. Requesting elevation..." -ForegroundColor Yellow
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $SubAction"
        if ($SubTarget) {
            $argList += " $SubTarget"
        }
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
        } catch {
            Write-Error "Failed to elevate. Please run this command from an elevated (Administrator) terminal."
        }
        exit
    }
}

function Get-VlessBoxProcess {
    if (Test-Path $vlessPidFile) {
        $pidVal = (Get-Content $vlessPidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($pidVal -match '^\d+$') {
            $proc = Get-Process -Id ([int]$pidVal) -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like "*sing-box*") {
                return $proc
            }
        }
    }
    # Fallback: find sing-box started with our config file
    try {
        $cims = Get-CimInstance Win32_Process -Filter "Name='sing-box.exe'" -ErrorAction Stop
        foreach ($c in $cims) {
            if ($c.CommandLine -and $c.CommandLine -like "*config.vless.json*") {
                $proc = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue
                if ($proc) { return $proc }
            }
        }
    } catch {}
    return $null
}

function Get-OtherSingBoxProcesses {
    $mine = Get-VlessBoxProcess
    $all = @(Get-Process -Name "sing-box" -ErrorAction SilentlyContinue)
    if ($mine) {
        return @($all | Where-Object { $_.Id -ne $mine.Id })
    }
    return $all
}

function Get-MixedProxyPortProcess {
    try {
        $conn = Get-NetTCPConnection -LocalPort $mixedPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn -and $conn.OwningProcess) {
            return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        }
    } catch {}
    return $null
}

function Test-IsPlaceholder {
    param($Value)
    if ($null -eq $Value) { return $true }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $true }
    return ($s -match '<.*>' -or $s -match 'YOUR_')
}

function Test-VlessConfig {
    $result = [ordered]@{
        Valid             = $false
        HasPlaceholders   = $false
        PlaceholderFields = @()
        ProxyOutbound     = $null
        Error             = $null
    }
    if (-not (Test-Path $configPath)) {
        $result.Error = "config.vless.json not found at $configPath"
        return $result
    }
    try {
        $cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $result.Error = "config.vless.json is not valid JSON: $_"
        return $result
    }
    $proxy = $cfg.outbounds | Where-Object { $_.tag -eq "proxy" } | Select-Object -First 1
    if (-not $proxy) {
        $result.Error = "No outbound with tag 'proxy' found in config.vless.json"
        return $result
    }
    $result.ProxyOutbound = $proxy
    $bad = @()
    if (Test-IsPlaceholder $proxy.server) { $bad += "server" }
    if (Test-IsPlaceholder $proxy.uuid) { $bad += "uuid" }
    if ($proxy.tls -and $proxy.tls.reality -and $proxy.tls.reality.enabled) {
        if (Test-IsPlaceholder $proxy.tls.reality.public_key) { $bad += "tls.reality.public_key" }
        # short_id may legitimately be empty; only flag explicit placeholders
        $sid = $proxy.tls.reality.short_id
        if ($sid -and (([string]$sid) -match '<.*>' -or ([string]$sid) -match 'YOUR_')) { $bad += "tls.reality.short_id" }
    }
    $result.PlaceholderFields = $bad
    $result.HasPlaceholders = ($bad.Count -gt 0)
    $result.Valid = $true
    return $result
}

function Invoke-SingBoxCheck {
    # Returns @{ ExitCode; Output }
    $lines = & $singBoxExe check -c $configPath 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
    return @{ ExitCode = $code; Output = (($lines -join "`n").Trim()) }
}

function Mask-Text {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ($Text.Length -le 10) { return ("*" * $Text.Length) }
    return $Text.Substring(0, 4) + "..." + $Text.Substring($Text.Length - 4)
}

# --- Service Actions ---

function Import-VlessUri {
    if (-not $singBoxExe) {
        Write-Error "sing-box.exe not found."
        return
    }
    if (-not (Test-Path $configPath)) {
        Write-Error "config.vless.json not found at $configPath"
        return
    }

    $uriInput = $Target
    if ([string]::IsNullOrWhiteSpace($uriInput)) {
        $uriInput = Read-Host "Paste vless:// URI"
    }
    $uriInput = $uriInput.Trim().Trim('"').Trim("'").Trim()
    if (-not $uriInput.StartsWith("vless://", [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "Not a vless:// URI. Tip: wrap the link in single quotes, or run 'vlessbox import' and paste when prompted."
        return
    }

    try {
        $uri = [System.Uri]$uriInput
    } catch {
        Write-Error "Failed to parse URI: $_"
        return
    }

    $uuid = [System.Uri]::UnescapeDataString($uri.UserInfo)
    $server = $uri.Host.Trim('[', ']')
    $port = if ($uri.Port -gt 0) { $uri.Port } else { 443 }
    if ([string]::IsNullOrWhiteSpace($uuid) -or [string]::IsNullOrWhiteSpace($server)) {
        Write-Error "URI is missing uuid or server address."
        return
    }

    $q = @{}
    $queryStr = $uri.Query.TrimStart('?')
    if ($queryStr) {
        foreach ($pair in ($queryStr -split '&')) {
            if (-not $pair) { continue }
            $kv = $pair -split '=', 2
            $k = [System.Uri]::UnescapeDataString($kv[0]).ToLower()
            $v = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) } else { "" }
            $q[$k] = $v
        }
    }

    $type = if ($q.ContainsKey("type") -and $q["type"]) { $q["type"] } else { "tcp" }
    if ($type -ne "tcp") {
        Write-Warning "URI has type=$type. 'vlessbox import' only supports type=tcp (Vision + Reality). Aborting."
        return
    }
    $security = if ($q.ContainsKey("security") -and $q["security"]) { $q["security"] } else { "reality" }
    $flow = if ($q.ContainsKey("flow")) { $q["flow"] } else { "" }
    $sni = if ($q.ContainsKey("sni")) { $q["sni"] } else { "" }
    $fp = if ($q.ContainsKey("fp") -and $q["fp"]) { $q["fp"] } else { "chrome" }
    $pbk = if ($q.ContainsKey("pbk")) { $q["pbk"] } else { "" }
    $sid = if ($q.ContainsKey("sid")) { $q["sid"] } else { "" }
    $remark = [System.Uri]::UnescapeDataString($uri.Fragment.TrimStart('#'))

    if ($security -eq "reality") {
        if ([string]::IsNullOrWhiteSpace($pbk) -or [string]::IsNullOrWhiteSpace($sni)) {
            Write-Error "security=reality requires both 'pbk' (public key) and 'sni' in the URI."
            return
        }
    } elseif ($security -ne "tls" -and $security -ne "none") {
        Write-Error "Unsupported security=$security"
        return
    }

    $tls = [ordered]@{ enabled = $true }
    if ($security -eq "none") {
        $tls = [ordered]@{ enabled = $false }
    } else {
        if ($sni) { $tls["server_name"] = $sni }
        $tls["utls"] = [ordered]@{ enabled = $true; fingerprint = $fp }
        if ($security -eq "reality") {
            $tls["reality"] = [ordered]@{ enabled = $true; public_key = $pbk; short_id = $sid }
        }
    }

    $newOutbound = [ordered]@{
        type        = "vless"
        tag         = "proxy"
        server      = $server
        server_port = [int]$port
        uuid        = $uuid
    }
    if ($flow) { $newOutbound["flow"] = $flow }
    $newOutbound["packet_encoding"] = "xudp"
    $newOutbound["domain_resolver"] = "dns-direct"
    $newOutbound["tls"] = $tls

    try {
        $cfg = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Error "Existing config.vless.json is not valid JSON: $_"
        return
    }

    $outs = @($cfg.outbounds)
    $idx = -1
    for ($i = 0; $i -lt $outs.Count; $i++) {
        if ($outs[$i].tag -eq "proxy") { $idx = $i; break }
    }
    if ($idx -lt 0) {
        Write-Error "No 'proxy' outbound found in config.vless.json"
        return
    }
    $outs[$idx] = $newOutbound
    $cfg.outbounds = $outs

    $json = $cfg | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($configPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "              VLESS URI Imported                  " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  Remark:      $remark"
    Write-Host "  Server:      ${server}:${port}"
    Write-Host "  UUID:        $(Mask-Text $uuid)"
    Write-Host "  Security:    $security"
    Write-Host "  Flow:        $flow"
    Write-Host "  SNI:         $sni"
    Write-Host "  Fingerprint: $fp"
    if ($security -eq "reality") {
        Write-Host "  Public Key:  $(Mask-Text $pbk)"
        Write-Host "  Short ID:    $sid"
    }
    Write-Host ""
    $chk = Invoke-SingBoxCheck
    if ($chk.ExitCode -eq 0) {
        Write-Host "[sing-box check] OK - config is valid." -ForegroundColor Green
        if ($chk.Output) { Write-Host $chk.Output -ForegroundColor Yellow }
        Write-Host "Run 'vlessbox start' to connect." -ForegroundColor Gray
    } else {
        Write-Host "[sing-box check] FAILED (exit $($chk.ExitCode)):" -ForegroundColor Red
        Write-Host $chk.Output -ForegroundColor Red
    }
}

function Check-VlessBox {
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "              VlessBox Config Check               " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    if ($singBoxExe) {
        Write-Host "[sing-box] $singBoxExe" -ForegroundColor Green
    } else {
        Write-Host "[sing-box] sing-box.exe NOT FOUND" -ForegroundColor Red
        return
    }

    $v = Test-VlessConfig
    if ($v.Error) {
        Write-Host "[config] $($v.Error)" -ForegroundColor Red
        return
    }
    if ($v.HasPlaceholders) {
        Write-Host "[config] Placeholders still present in: $($v.PlaceholderFields -join ', ')" -ForegroundColor Yellow
        Write-Host "         Run 'vlessbox import' to import your vless:// URI." -ForegroundColor Yellow
    } else {
        Write-Host "[config] Credentials configured." -ForegroundColor Green
    }

    $chk = Invoke-SingBoxCheck
    if ($chk.ExitCode -eq 0) {
        Write-Host "[sing-box check] OK" -ForegroundColor Green
        if ($chk.Output) { Write-Host $chk.Output -ForegroundColor Yellow }
    } else {
        Write-Host "[sing-box check] FAILED (exit $($chk.ExitCode)):" -ForegroundColor Red
        Write-Host $chk.Output -ForegroundColor Red
    }
}

function Start-VlessBox {
    Ensure-Admin "start"

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "              Starting VlessBox Service           " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    if (-not $singBoxExe) {
        Write-Error "sing-box.exe not found."
        return
    }
    if (-not (Test-Path $configPath)) {
        Write-Error "config.vless.json not found at $configPath"
        return
    }

    # Validate BEFORE disturbing any running service
    $v = Test-VlessConfig
    if ($v.Error) {
        Write-Host "[config] $($v.Error)" -ForegroundColor Red
        return
    }
    if ($v.HasPlaceholders) {
        Write-Host "[config] Placeholders still present in: $($v.PlaceholderFields -join ', ')" -ForegroundColor Red
        Write-Host "         Run 'vlessbox import' to import your vless:// URI." -ForegroundColor Yellow
        return
    }
    $chk = Invoke-SingBoxCheck
    if ($chk.ExitCode -ne 0) {
        Write-Host "[sing-box check] FAILED (exit $($chk.ExitCode)):" -ForegroundColor Red
        Write-Host $chk.Output -ForegroundColor Red
        return
    }

    $mine = Get-VlessBoxProcess
    if ($mine) {
        Write-Host "[VlessBox] Already running (PID: $($mine.Id))." -ForegroundColor Green
        return
    }

    $others = @(Get-OtherSingBoxProcesses)
    if ($others.Count -gt 0) {
        foreach ($p in $others) {
            Write-Host "[Conflict] Another sing-box instance (PID: $($p.Id)) is running, likely from Tailbox. Stopping it to avoid TUN conflict..." -ForegroundColor Yellow
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $tailboxSingBoxPidFile) {
            Remove-Item $tailboxSingBoxPidFile -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }

    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    foreach ($lf in @($singBoxLog, $singBoxErrLog)) {
        if (Test-Path $lf) {
            if ((Get-Item $lf).Length -gt 5MB) {
                Move-Item -Path $lf -Destination "$lf.bak" -Force
            }
        }
    }

    Write-Host "[VlessBox] Launching sing-box in background..." -ForegroundColor Yellow
    $newProc = Start-Process -FilePath $singBoxExe `
        -ArgumentList "run -c `"$configPath`"" `
        -WorkingDirectory $singBoxDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $singBoxLog `
        -RedirectStandardError $singBoxErrLog `
        -PassThru

    Set-Content -Path $vlessPidFile -Value $newProc.Id

    Start-Sleep -Seconds 2
    if ($newProc.HasExited) {
        Write-Host "[VlessBox] Failed to start or exited immediately. Last log lines:" -ForegroundColor Red
        if (Test-Path $singBoxErrLog) {
            Get-Content $singBoxErrLog -Tail 20
        }
        Remove-Item $vlessPidFile -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Host "[VlessBox] Started successfully (PID: $($newProc.Id))." -ForegroundColor Green
    if (Get-MixedProxyPortProcess) {
        Write-Host "[VlessBox] Mixed proxy 127.0.0.1:$mixedPort listening." -ForegroundColor Green
    } else {
        Write-Warning "Mixed proxy port $mixedPort is not listening yet. Check 'vlessbox log'."
    }
    try {
        $tunNet = Get-NetAdapter -Name "*sing-box*" -ErrorAction SilentlyContinue
        if ($tunNet) {
            Write-Host "[VlessBox] TUN adapter: $($tunNet.Name) ($($tunNet.Status))" -ForegroundColor Green
        }
    } catch {}

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "VlessBox is now active in background." -ForegroundColor Green
    Write-Host "Use 'vlessbox status' to inspect or 'vlessbox log' to view logs." -ForegroundColor Gray
    Write-Host "==================================================" -ForegroundColor Cyan
    Start-Sleep -Seconds 1
}

function Stop-VlessBox {
    Ensure-Admin "stop"

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "              Stopping VlessBox Service           " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    $mine = Get-VlessBoxProcess
    if ($mine) {
        Write-Host "[VlessBox] Stopping sing-box (PID: $($mine.Id))..." -ForegroundColor Yellow
        Stop-Process -Id $mine.Id -Force -ErrorAction SilentlyContinue
        Write-Host "[VlessBox] Stopped." -ForegroundColor Green
    } else {
        Write-Host "[VlessBox] Not running." -ForegroundColor Gray
        $others = @(Get-OtherSingBoxProcesses)
        if ($others.Count -gt 0) {
            Write-Host "[Note] Another sing-box (PID: $($others[0].Id)) is running, likely Tailbox. Use 'tailbox stop' to stop Tailbox." -ForegroundColor Yellow
        }
    }
    if (Test-Path $vlessPidFile) {
        Remove-Item $vlessPidFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "==================================================" -ForegroundColor Cyan
    Start-Sleep -Seconds 1
}

function Show-Status {
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "              VlessBox Service Status             " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    Write-Host "[sing-box]" -ForegroundColor White
    if ($singBoxExe) {
        $ver = ""
        try { $ver = (& $singBoxExe version 2>$null | Select-Object -First 1) } catch {}
        Write-Host "  Binary:        $singBoxExe" -ForegroundColor Gray
        if ($ver) { Write-Host "  Version:       $ver" -ForegroundColor Gray }
    } else {
        Write-Host "  Binary:        NOT FOUND" -ForegroundColor Red
    }

    $mine = Get-VlessBoxProcess
    if ($mine) {
        $memMB = [math]::Round($mine.WorkingSet64 / 1MB, 1)
        Write-Host "  Daemon:        RUNNING (PID: $($mine.Id), Memory: ${memMB} MB)" -ForegroundColor Green
    } else {
        Write-Host "  Daemon:        STOPPED" -ForegroundColor Red
        $others = @(Get-OtherSingBoxProcesses)
        if ($others.Count -gt 0) {
            Write-Host "  Note:          Another sing-box (PID: $($others[0].Id)) is running, likely Tailbox." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "[VLESS Config]" -ForegroundColor White
    $v = Test-VlessConfig
    if ($v.Error) {
        Write-Host "  Config:        $($v.Error)" -ForegroundColor Red
    } else {
        $p = $v.ProxyOutbound
        $flow = if ($p.flow) { $p.flow } else { "(none)" }
        $sni = if ($p.tls -and $p.tls.server_name) { $p.tls.server_name } else { "(none)" }
        $fp = if ($p.tls -and $p.tls.utls -and $p.tls.utls.fingerprint) { $p.tls.utls.fingerprint } else { "(none)" }
        Write-Host "  Server:        $($p.server):$($p.server_port)"
        Write-Host "  SNI:           $sni"
        Write-Host "  Flow:          $flow"
        Write-Host "  Fingerprint:   $fp"
        if ($v.HasPlaceholders) {
            Write-Host "  Credentials:   PLACEHOLDERS in: $($v.PlaceholderFields -join ', ') (run 'vlessbox import')" -ForegroundColor Yellow
        } else {
            Write-Host "  Credentials:   Configured" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "[Local Proxy]" -ForegroundColor White
    if (Get-MixedProxyPortProcess) {
        Write-Host "  Mixed Proxy:   127.0.0.1:$mixedPort (Listening)" -ForegroundColor Green
    } else {
        Write-Host "  Mixed Proxy:   127.0.0.1:$mixedPort (Offline)" -ForegroundColor Gray
    }
    try {
        $tunNet = Get-NetAdapter -Name "*sing-box*" -ErrorAction SilentlyContinue
        if ($tunNet) {
            Write-Host "  TUN Adapter:   $($tunNet.Name) ($($tunNet.Status))" -ForegroundColor Green
        } else {
            Write-Host "  TUN Adapter:   Not active" -ForegroundColor Gray
        }
    } catch {}

    Write-Host "==================================================" -ForegroundColor Cyan
}

function Show-Logs {
    # sing-box writes all logs (INFO/WARN/ERROR) to stderr
    if ((Test-Path $singBoxLog) -and ((Get-Item $singBoxLog).Length -gt 0)) {
        Write-Host "--- Recent stdout ($singBoxLog) ---" -ForegroundColor Yellow
        Get-Content -Path $singBoxLog -Tail 10 -ErrorAction SilentlyContinue
        Write-Host "-----------------------------------" -ForegroundColor Gray
    }
    if (-not (Test-Path $singBoxErrLog)) {
        Write-Warning "Log file not found at: $singBoxErrLog"
        return
    }
    Write-Host "Tailing vlessbox log (Ctrl+C to stop)..." -ForegroundColor Cyan
    Get-Content -Path $singBoxErrLog -Tail 40 -Wait
}

function Install-Path {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $dirs = $userPath -split ';' | Where-Object { $_ -ne "" }
    if ($dirs -contains $scriptDir) {
        Write-Host "Directory '$scriptDir' is already in your User PATH." -ForegroundColor Green
    } else {
        $newUserPath = "$userPath;$scriptDir"
        [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
        Write-Host "Successfully added '$scriptDir' to User PATH!" -ForegroundColor Green
        Write-Host "Please restart your terminal to use 'vlessbox' anywhere directly." -ForegroundColor Yellow
    }
}

function Show-Help {
    Write-Host @"
VlessBox Service Controller (sing-box + VLESS/Reality)

Usage:
  vlessbox <command> [arguments]

Commands:
  import [uri]      Import a vless:// link into config.vless.json
                    (run without args to paste interactively - recommended;
                     or quote it: vlessbox import 'vless://...')
  check             Validate config.vless.json (placeholders + sing-box check)
  start             Start sing-box (TUN + 127.0.0.1:10808 mixed proxy) in background
                    Note: stops a running Tailbox sing-box first (they share the TUN)
  stop              Stop the VlessBox sing-box (does not touch Tailbox)
  restart           Restart VlessBox
  status            Show running status, config summary and proxy ports
  log               Tail live logs (sing-box writes to logs\vlessbox.err.log)
  install-path      Add current directory to User PATH
  help              Show this help message

Examples:
  vlessbox import
  vlessbox import 'vless://UUID@1.2.3.4:443?...#MyReality'
  vlessbox start
  vlessbox status
  vlessbox log
"@ -ForegroundColor Cyan
}

# --- Command Router ---
switch ($Action.ToLower()) {
    "start"        { Start-VlessBox }
    "stop"         { Stop-VlessBox }
    "restart"      { Stop-VlessBox; Start-Sleep -Seconds 2; Start-VlessBox }
    "status"       { Show-Status }
    "log"          { Show-Logs }
    "logs"         { Show-Logs }
    "check"        { Check-VlessBox }
    "import"       { Import-VlessUri }
    "install-path" { Install-Path }
    "help"         { Show-Help }
    default        {
        if ([string]::IsNullOrWhiteSpace($Action)) {
            Show-Status
        } else {
            Write-Warning "Unknown command: '$Action'"
            Show-Help
        }
    }
}
