# Check if the current session is running with Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Define Tailscale paths
$tailscaleClient = "C:\Program Files\Tailscale\tailscale-ipn.exe"
if (-not (Test-Path $tailscaleClient)) {
    $tailscaleClient = "C:\Program Files\Tailscale IPN\tailscale-ipn.exe"
}

if (-not (Test-Path $tailscaleClient)) {
    Write-Error "Tailscale client (tailscale-ipn.exe) not found."
    exit 1
}

$tailscaleDir = Split-Path $tailscaleClient -Parent
$tailscaledPath = Join-Path $tailscaleDir "tailscaled.exe"
$tailscaleCli = Join-Path $tailscaleDir "tailscale.exe"

# 1. Determine if we need administrator privileges
$needAdmin = $false

# We need admin privileges if tailscaled is not running and we need to start it
$tailscaledProcess = Get-Process -Name "tailscaled" -ErrorAction SilentlyContinue
if (-not $tailscaledProcess) {
    $needAdmin = $true
}

# We also check if sing-box config uses TUN mode, which requires admin privileges
$singBoxDir = "D:\Program Files\sing-box-1.14.1-windows-amd64"
$singBoxConfig = Join-Path $singBoxDir "config.json"
$singBoxNeedsAdmin = $false

if (Test-Path $singBoxConfig) {
    try {
        $configContent = Get-Content $singBoxConfig -Raw -ErrorAction SilentlyContinue
        if ($configContent -match '"type"\s*:\s*"tun"') {
            $singBoxNeedsAdmin = $true
            $needAdmin = $true
        }
    } catch {
        # Ignore configuration read errors, assume non-admin if parsing fails
    }
}

# If admin privileges are needed but we don't have them, request elevation
if ($needAdmin -and -not $isAdmin) {
    Write-Host "Requesting Administrator privileges to run Tailscale/sing-box..." -ForegroundColor Yellow
    try {
        $arguments = "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Start-Process powershell -Verb RunAs -ArgumentList $arguments
        exit
    } catch {
        Write-Error "Failed to elevate process. Administrator privileges are required to start Tailscale/sing-box in this configuration."
        exit 1
    }
}

# 2. Start Tailscale daemon (tailscaled) if not already running
if (-not $tailscaledProcess) {
    Write-Host "Starting Tailscale daemon (tailscaled)..." -ForegroundColor Cyan
    # $tailscaledArgs = "--tun=userspace-networking --socks5-server=127.0.0.1:1080 --outbound-http-proxy-listen=127.0.0.1:3128"
    $tailscaledArgs = "--tun=userspace-networking --socks5-server=127.0.0.1:1080"
    
    # Check if we are running in Windows Terminal
    $isWT = $env:WT_SESSION -ne $null
    if ($isWT -and (Get-Command wt -ErrorAction SilentlyContinue)) {
        # Split the terminal to run tailscaled in a new pane
        wt -w 0 split-pane powershell -NoExit -Command "& '$tailscaledPath' $tailscaledArgs"
    } else {
        # Fallback to a new window if wt is not available or not running inside WT
        Start-Process powershell -ArgumentList "-NoExit", "-Command", "& '$tailscaledPath' $tailscaledArgs"
    }
} else {
    Write-Host "Tailscale daemon (tailscaled) is already running." -ForegroundColor Green
}

# Wait for tailscaled daemon to start up and respond
Write-Host "Waiting for Tailscale daemon to respond..." -ForegroundColor Cyan
$timeout = 15
$elapsed = 0
$daemonReady = $false
while ($elapsed -lt $timeout) {
    $statusOutput = & $tailscaleCli status 2>&1 | Out-String
    if ($statusOutput -notmatch "failed to connect to local tailscaled") {
        $daemonReady = $true
        break
    }
    Start-Sleep -Seconds 1
    $elapsed++
}

if (-not $daemonReady) {
    Write-Warning "Tailscale daemon did not respond in time. Proceeding anyway..."
} else {
    Write-Host "Tailscale daemon is responding." -ForegroundColor Green
}

# 3. Start Tailscale client GUI if not already running
$ipnProcess = Get-Process -Name "tailscale-ipn" -ErrorAction SilentlyContinue
if (-not $ipnProcess) {
    Write-Host "Starting Tailscale client GUI..." -ForegroundColor Cyan
    if ($isAdmin) {
        # If running as Admin, launch GUI client as non-elevated using explorer.exe
        Start-Process "explorer.exe" -ArgumentList "`"$tailscaleClient`""
    } else {
        # If running as standard user, run it directly
        Start-Process "$tailscaleClient"
    }
} else {
    Write-Host "Tailscale client GUI is already running." -ForegroundColor Green
}

# 4. Wait for Tailscale network connection (IP assignment) to complete
Write-Host "Waiting for Tailscale network connection (IP address assignment)..." -ForegroundColor Cyan
$connected = $false
$elapsed = 0
while ($elapsed -lt 10) {
    $ipOutput = & $tailscaleCli ip 2>&1 | Out-String
    # A valid Tailscale IP is typically in the 100.64.0.0/10 range, or IPv6
    if ($ipOutput -match "\b100\.\d{1,3}\.\d{1,3}\.\d{1,3}\b" -or $ipOutput -match "^[0-9a-fA-F:]+$") {
        Write-Host "Tailscale is connected. IP(s): $($ipOutput.Trim())" -ForegroundColor Green
        $connected = $true
        break
    }
    Start-Sleep -Seconds 1
    $elapsed++
}

if (-not $connected) {
    Write-Warning "Tailscale IP check timed out. Proceeding to launch sing-box anyway..."
}

Start-Sleep -Seconds 2

# 5. Start sing-box in the current pane/window (blocking, logs shown here)
if (Test-Path $singBoxDir) {
    Write-Host "Starting sing-box..." -ForegroundColor Cyan
    try {
        & $singBoxDir\sing-box.exe run -c .\config.json
    } finally {
    }
} else {
    Write-Error "sing-box directory not found: $singBoxDir"
}
