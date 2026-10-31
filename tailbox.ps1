<#
.SYNOPSIS
    Tailbox Service Controller (Tailscale userspace socks5 + sing-box TUN)
.DESCRIPTION
    Allows managing Tailbox as a background service via start, stop, restart, status, and logs.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "restart", "status", "log", "logs", "install-path", "help", "", $null)]
    [string]$Action = "status",

    [Parameter(Position = 1)]
    [string]$Target = "singbox"
)

# --- Configuration & Paths ---
$scriptDir = $PSScriptRoot

# Tailscale Paths
$tailscaleClient = "C:\Program Files\Tailscale\tailscale-ipn.exe"
if (-not (Test-Path $tailscaleClient)) {
    $tailscaleClient = "C:\Program Files\Tailscale IPN\tailscale-ipn.exe"
}
$tailscaleDir = if (Test-Path $tailscaleClient) { Split-Path $tailscaleClient -Parent } else { "" }
$tailscaledPath = if ($tailscaleDir) { Join-Path $tailscaleDir "tailscaled.exe" } else { "" }
$tailscaleCli = if ($tailscaleDir) { Join-Path $tailscaleDir "tailscale.exe" } else { "" }

# sing-box Paths
$singBoxDir = "D:\Program Files\sing-box-1.14.1-windows-amd64"
$singBoxExe = Join-Path $singBoxDir "sing-box.exe"
$configPath = Join-Path $scriptDir "config.json"

# Logging and Runtime Files
$logDir = Join-Path $scriptDir "logs"
$singBoxLog = Join-Path $logDir "sing-box.log"
$singBoxErrLog = Join-Path $logDir "sing-box.err.log"
$tailscaledLog = Join-Path $logDir "tailscaled.log"
$tailscaledErrLog = Join-Path $logDir "tailscaled.err.log"
$singBoxPidFile = Join-Path $scriptDir ".singbox.pid"
$tailscaledPidFile = Join-Path $scriptDir ".tailscaled.pid"

# --- Helper Functions ---

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

function Get-Socks5PortProcess {
    try {
        $conn = Get-NetTCPConnection -LocalPort 1080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn -and $conn.OwningProcess) {
            return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        }
    } catch {}
    return $null
}

function Get-HttpProxyPortProcess {
    try {
        $conn = Get-NetTCPConnection -LocalPort 10808 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn -and $conn.OwningProcess) {
            return Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        }
    } catch {}
    return $null
}

function Get-SingBoxProcess {
    if (Test-Path $singBoxPidFile) {
        $pidVal = Get-Content $singBoxPidFile -ErrorAction SilentlyContinue
        if ($pidVal -match '^\d+$') {
            $proc = Get-Process -Id ([int]$pidVal) -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like "*sing-box*") {
                return $proc
            }
        }
    }
    # Fallback to process by name
    return Get-Process -Name "sing-box" -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Get-TailscaledUserspaceProcess {
    # 1. From recorded PID
    if (Test-Path $tailscaledPidFile) {
        $pidVal = Get-Content $tailscaledPidFile -ErrorAction SilentlyContinue
        if ($pidVal -match '^\d+$') {
            $proc = Get-Process -Id ([int]$pidVal) -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like "*tailscaled*") {
                return $proc
            }
        }
    }
    # 2. From process listening on 1080
    $p = Get-Socks5PortProcess
    if ($p -and $p.ProcessName -like "*tailscaled*") {
        return $p
    }
    return $null
}

# --- Service Actions ---

function Start-Tailbox {
    Ensure-Admin "start"

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "              Starting Tailbox Service            " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    # Verify binaries and configs
    if (-not (Test-Path $tailscaledPath)) {
        Write-Error "tailscaled.exe not found at $tailscaledPath"
        return
    }
    if (-not (Test-Path $singBoxExe)) {
        Write-Error "sing-box.exe not found at $singBoxExe"
        return
    }
    if (-not (Test-Path $configPath)) {
        Write-Error "config.json not found at $configPath"
        return
    }

    # 0. Stop official Tailscale Windows Service if running to avoid Named Pipe conflict
    try {
        $officialSvc = Get-Service -Name "Tailscale" -ErrorAction SilentlyContinue
        if ($officialSvc -and $officialSvc.Status -eq "Running") {
            Write-Host "[Tailscaled] Official Windows Service 'Tailscale' is running. Stopping it..." -ForegroundColor Yellow
            Stop-Service -Name "Tailscale" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Write-Host "[Tailscaled] Official Windows Service stopped." -ForegroundColor Green
        }
    } catch {
        Write-Warning "[Tailscaled] Could not stop official Tailscale service: $_"
    }

    # 1. Start Tailscaled (userspace networking)
    $tsProc = Get-TailscaledUserspaceProcess
    if ($tsProc) {
        Write-Host "[Tailscaled] Daemon is already running (PID: $($tsProc.Id))." -ForegroundColor Green
    } else {
        Write-Host "[Tailscaled] Launching daemon in background..." -ForegroundColor Yellow
        
        # Rotate previous log if > 5MB
        if (Test-Path $tailscaledLog) {
            $logItem = Get-Item $tailscaledLog
            if ($logItem.Length -gt 5MB) {
                Move-Item -Path $tailscaledLog -Destination "$tailscaledLog.bak" -Force
            }
        }

        $tailscaledArgs = "--tun=userspace-networking --socks5-server=127.0.0.1:1080"
        $newTsProc = Start-Process -FilePath $tailscaledPath `
            -ArgumentList $tailscaledArgs `
            -WindowStyle Hidden `
            -RedirectStandardOutput $tailscaledLog `
            -RedirectStandardError $tailscaledErrLog `
            -PassThru

        Set-Content -Path $tailscaledPidFile -Value $newTsProc.Id

        # Wait for Socks5 port (1080) to be ready
        Write-Host "[Tailscaled] Waiting for Socks5 proxy (127.0.0.1:1080) to listen..." -ForegroundColor Gray
        $ready = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            $checkProc = Get-Socks5PortProcess
            if ($checkProc) {
                $ready = $true
                break
            }
        }

        if ($ready) {
            Write-Host "[Tailscaled] Daemon started successfully (PID: $($newTsProc.Id))." -ForegroundColor Green
        } else {
            Write-Warning "[Tailscaled] Daemon started but port 1080 is not listening yet. Check logs/tailscaled.log"
        }
    }

    # 2. Start Tailscale GUI client if not running
    $guiProc = Get-Process -Name "tailscale-ipn" -ErrorAction SilentlyContinue
    if (-not $guiProc -and (Test-Path $tailscaleClient)) {
        Write-Host "[GUI] Starting Tailscale tray client..." -ForegroundColor Gray
        Start-Process "explorer.exe" -ArgumentList "`"$tailscaleClient`""
    }

    # 3. Start sing-box
    $sbProc = Get-SingBoxProcess
    if ($sbProc) {
        Write-Host "[sing-box] Service is already running (PID: $($sbProc.Id))." -ForegroundColor Green
    } else {
        Write-Host "[sing-box] Launching sing-box in background..." -ForegroundColor Yellow

        if (Test-Path $singBoxLog) {
            $logItem = Get-Item $singBoxLog
            if ($logItem.Length -gt 5MB) {
                Move-Item -Path $singBoxLog -Destination "$singBoxLog.bak" -Force
            }
        }

        $newSbProc = Start-Process -FilePath $singBoxExe `
            -ArgumentList "run -c `"$configPath`"" `
            -WorkingDirectory $singBoxDir `
            -WindowStyle Hidden `
            -RedirectStandardOutput $singBoxLog `
            -RedirectStandardError $singBoxErrLog `
            -PassThru

        Set-Content -Path $singBoxPidFile -Value $newSbProc.Id

        Start-Sleep -Seconds 2
        if (-not $newSbProc.HasExited) {
            Write-Host "[sing-box] Started successfully (PID: $($newSbProc.Id))." -ForegroundColor Green
        } else {
            Write-Error "[sing-box] Failed to start or exited immediately. Check logs/sing-box.err.log"
            if (Test-Path $singBoxErrLog) {
                Get-Content $singBoxErrLog -Tail 15
            }
            return
        }
    }

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "Tailbox service is now active in background." -ForegroundColor Green
    Write-Host "Use 'tailbox status' to inspect or 'tailbox log' to view logs." -ForegroundColor Gray
    Write-Host "==================================================" -ForegroundColor Cyan
    Start-Sleep -Seconds 1
}

function Stop-Tailbox {
    Ensure-Admin "stop"

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "              Stopping Tailbox Service            " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    # 1. Stop sing-box
    $sbProcs = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
    if ($sbProcs) {
        foreach ($p in $sbProcs) {
            Write-Host "[sing-box] Stopping process (PID: $($p.Id))..." -ForegroundColor Yellow
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[sing-box] Stopped." -ForegroundColor Green
    } else {
        Write-Host "[sing-box] Not running." -ForegroundColor Gray
    }
    if (Test-Path $singBoxPidFile) {
        Remove-Item $singBoxPidFile -Force -ErrorAction SilentlyContinue
    }

    # 2. Stop userspace tailscaled
    $tsProc = Get-TailscaledUserspaceProcess
    if ($tsProc) {
        Write-Host "[Tailscaled] Stopping userspace daemon (PID: $($tsProc.Id))..." -ForegroundColor Yellow
        Stop-Process -Id $tsProc.Id -Force -ErrorAction SilentlyContinue
        Write-Host "[Tailscaled] Stopped." -ForegroundColor Green
    } else {
        Write-Host "[Tailscaled] Userspace daemon is not running." -ForegroundColor Gray
    }
    if (Test-Path $tailscaledPidFile) {
        Remove-Item $tailscaledPidFile -Force -ErrorAction SilentlyContinue
    }

    # 3. Stop GUI client
    $guiProcs = Get-Process -Name "tailscale-ipn" -ErrorAction SilentlyContinue
    if ($guiProcs) {
        foreach ($p in $guiProcs) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[GUI] Tailscale client GUI closed." -ForegroundColor Gray
    }

    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "Tailbox service has been completely stopped." -ForegroundColor Green
    Write-Host "==================================================" -ForegroundColor Cyan
    Start-Sleep -Seconds 1
}

function Show-Status {
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "              Tailbox Service Status              " -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan

    # 1. Tailscaled status
    $tsProc = Get-TailscaledUserspaceProcess
    $socksPort = Get-Socks5PortProcess
    Write-Host "[Tailscaled]" -ForegroundColor White
    if ($tsProc) {
        Write-Host "  Daemon:        RUNNING (PID: $($tsProc.Id))" -ForegroundColor Green
        if ($socksPort) {
            Write-Host "  Socks5 Proxy:  127.0.0.1:1080 (Listening)" -ForegroundColor Green
        } else {
            Write-Host "  Socks5 Proxy:  127.0.0.1:1080 (Not listening)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Daemon:        STOPPED" -ForegroundColor Red
        Write-Host "  Socks5 Proxy:  127.0.0.1:1080 (Offline)" -ForegroundColor Gray
    }

    # Tailscale IP
    if ($tailscaleCli -and (Test-Path $tailscaleCli)) {
        try {
            $tsIps = & $tailscaleCli ip 2>$null
            if ($tsIps) {
                $ips = ($tsIps -split "`r?`n") | Where-Object { $_.Trim() -ne "" }
                $first = $true
                foreach ($ip in $ips) {
                    if ($first) {
                        Write-Host "  Tailscale IP:  $($ip.Trim())" -ForegroundColor Green
                        $first = $false
                    } else {
                        Write-Host "                 $($ip.Trim())" -ForegroundColor Green
                    }
                }
            } else {
                Write-Host "  Tailscale IP:  Disconnected" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  Tailscale IP:  Unavailable" -ForegroundColor Gray
        }
    }

    Write-Host ""
    # 2. sing-box status
    $sbProc = Get-SingBoxProcess
    $httpPort = Get-HttpProxyPortProcess
    Write-Host "[sing-box]" -ForegroundColor White
    if ($sbProc) {
        $memMB = [math]::Round($sbProc.WorkingSet64 / 1MB, 1)
        Write-Host "  Daemon:        RUNNING (PID: $($sbProc.Id), Memory: ${memMB} MB)" -ForegroundColor Green
        if ($httpPort) {
            Write-Host "  HTTP Proxy:    127.0.0.1:10808 (Listening)" -ForegroundColor Green
        } else {
            Write-Host "  HTTP Proxy:    127.0.0.1:10808 (Offline)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  Daemon:        STOPPED" -ForegroundColor Red
        Write-Host "  HTTP Proxy:    127.0.0.1:10808 (Offline)" -ForegroundColor Gray
    }

    # TUN Interface check
    try {
        $tunNet = Get-NetAdapter -Name "*sing-box*" -ErrorAction SilentlyContinue
        if ($tunNet) {
            Write-Host "  TUN Adapter:   $($tunNet.Name) ($($tunNet.Status))" -ForegroundColor Green
        } else {
            Write-Host "  TUN Adapter:   Not active" -ForegroundColor Gray
        }
    } catch {}

    Write-Host ""
    # 3. GUI Client
    $guiProc = Get-Process -Name "tailscale-ipn" -ErrorAction SilentlyContinue
    Write-Host "[GUI Client]" -ForegroundColor White
    if ($guiProc) {
        Write-Host "  Tray Icon:     RUNNING (PID: $($guiProc.Id))" -ForegroundColor Green
    } else {
        Write-Host "  Tray Icon:     Not running" -ForegroundColor Gray
    }

    Write-Host "==================================================" -ForegroundColor Cyan
}

function Show-Logs {
    param([string]$LogTarget)
    $fileToRead = $singBoxLog
    $errFile = $singBoxErrLog
    $title = "sing-box"
    if ($LogTarget -eq "tailscale" -or $LogTarget -eq "tailscaled" -or $LogTarget -eq "ts") {
        $fileToRead = $tailscaledLog
        $errFile = $tailscaledErrLog
        $title = "tailscaled"
    }

    if (Test-Path $errFile) {
        $errContent = Get-Content -Path $errFile -Tail 10 -ErrorAction SilentlyContinue
        if ($errContent) {
            Write-Host "--- Recent Errors ($errFile) ---" -ForegroundColor Yellow
            $errContent | ForEach-Object { Write-Host $_ -ForegroundColor Red }
            Write-Host "--------------------------------" -ForegroundColor Gray
        }
    }

    if (-not (Test-Path $fileToRead)) {
        Write-Warning "Log file not found at: $fileToRead"
        return
    }

    Write-Host "Tailing $title log (Ctrl+C to stop)..." -ForegroundColor Cyan
    Get-Content -Path $fileToRead -Tail 40 -Wait
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
        Write-Host "Please restart your terminal to use 'tailbox' anywhere directly." -ForegroundColor Yellow
    }
}

function Show-Help {
    Write-Host @"
Tailbox Service Controller

Usage:
  tailbox <command> [arguments]

Commands:
  start             Start tailscaled (userspace socks5) and sing-box in background
  stop              Stop all background tailbox services
  restart           Restart all tailbox services
  status            Show current running status, PIDs, proxy ports and Tailscale IP
  log [target]      Tail live logs (default: singbox; optional: tailscale)
  install-path      Add current directory to User PATH (allows running 'tailbox' from any folder)
  help              Show this help message

Examples:
  tailbox start
  tailbox stop
  tailbox status
  tailbox log
  tailbox log tailscale
"@ -ForegroundColor Cyan
}

# --- Command Router ---
switch ($Action.ToLower()) {
    "start"        { Start-Tailbox }
    "stop"         { Stop-Tailbox }
    "restart"      { Stop-Tailbox; Start-Sleep -Seconds 2; Start-Tailbox }
    "status"       { Show-Status }
    "log"          { Show-Logs -LogTarget $Target }
    "logs"         { Show-Logs -LogTarget $Target }
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
