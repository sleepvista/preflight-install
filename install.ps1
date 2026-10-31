<#
.SYNOPSIS
  Installs, or updates, Preflight on Windows and checks what it needs first.

.DESCRIPTION
  Run it by double-clicking install.cmd. Safe to run again: it works out what an
  earlier run, or a manual install, left behind before it writes anything, and it
  never deletes data or replaces a secret that is already in use.

  Read it before you run it; it is meant to be read. INSTALL.md describes every
  step it takes, by hand.

.PARAMETER Check
  Only run the read-only checks and report. Changes nothing. Exit code 1 if
  anything would stop the install.
#>
[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:ProjectPrefix = 'preflight-selfhost_'
$script:ApiPort = 8000
$script:HealthUrl = 'http://127.0.0.1:8000/health'
$script:RequiredKeys = @('PREFLIGHT_SECRET', 'POSTGRES_PASSWORD', 'PREFLIGHT_N8N_VERSION')
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogPath = Join-Path $script:Root 'install-log.txt'
$script:Secrets = New-Object System.Collections.ArrayList
# Why Docker Desktop could not be started, if it could not (Start-DockerDesktop).
# Set up here because the script runs under StrictMode: reading an unset
# variable is an error.
$script:DockerStartFailure = $null
$script:DockerStartError = ''

# Windows time zone id -> IANA name. Only ever a SUGGESTED default: the
# installer always asks, because a Windows id can be ambiguous (Mountain
# Standard Time is both Denver and Edmonton's neighbour) and a wrong zone makes
# dates look changed on replay.
$script:ZoneSuggestions = @{
    'Pacific Standard Time'        = 'America/Los_Angeles'
    'Mountain Standard Time'       = 'America/Denver'
    'Central Standard Time'        = 'America/Chicago'
    'Eastern Standard Time'        = 'America/New_York'
    'Atlantic Standard Time'       = 'America/Halifax'
    'Newfoundland Standard Time'   = 'America/St_Johns'
    'Canada Central Standard Time' = 'America/Regina'
    'Alaskan Standard Time'        = 'America/Anchorage'
    'Hawaiian Standard Time'       = 'Pacific/Honolulu'
    'GMT Standard Time'            = 'Europe/London'
    'W. Europe Standard Time'      = 'Europe/Berlin'
    'Romance Standard Time'        = 'Europe/Paris'
    'Central Europe Standard Time' = 'Europe/Budapest'
    'E. Europe Standard Time'      = 'Europe/Chisinau'
    'India Standard Time'          = 'Asia/Kolkata'
    'China Standard Time'          = 'Asia/Shanghai'
    'Tokyo Standard Time'          = 'Asia/Tokyo'
    'AUS Eastern Standard Time'    = 'Australia/Sydney'
    'New Zealand Standard Time'    = 'Pacific/Auckland'
    'UTC'                          = 'UTC'
}

# ---------------------------------------------------------------------------
# Output and the install log
#
# The log holds only lines this script chooses to write, with every registered
# secret replaced. It is not a transcript: Start-Transcript records whatever a
# native tool prints, which is how a token ends up in a file people are asked to
# email.
# ---------------------------------------------------------------------------

function Register-Secret {
    param([string]$Value)
    if ($Value -and $Value.Length -ge 4 -and -not $script:Secrets.Contains($Value)) {
        [void]$script:Secrets.Add($Value)
    }
}

function Protect-Text {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    foreach ($secret in $script:Secrets) {
        $Text = $Text.Replace($secret, '[hidden]')
    }
    return $Text
}

function Write-InstallLog {
    param([string]$Line)
    try {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $script:LogPath -Value ("$stamp  " + (Protect-Text $Line)) -Encoding UTF8
    }
    catch { }
}

function Write-Step { param([string]$Text) Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan; Write-InstallLog "STEP $Text" }
function Write-Ok { param([string]$Text) Write-Host "   ok: $Text" -ForegroundColor Green; Write-InstallLog "ok   $Text" }
function Write-Note { param([string]$Text) Write-Host "   $Text"; Write-InstallLog "note $Text" }
function Write-Warn { param([string]$Text) Write-Host "   WARNING: $Text" -ForegroundColor Yellow; Write-InstallLog "warn $Text" }
function Write-Problem { param([string]$Text) Write-Host "   STOP: $Text" -ForegroundColor Red; Write-InstallLog "STOP $Text" }

# A stop the tester can act on, as opposed to an unexpected error. Marked on the
# exception rather than by a class: a class defined here does not survive being
# dot-sourced into a test, and the marker does.
function Stop-Install {
    param([string]$Message)
    $exception = New-Object System.InvalidOperationException $Message
    $exception.Data['InstallStop'] = $true
    throw $exception
}

# ---------------------------------------------------------------------------
# Native commands
#
# In Windows PowerShell 5.1 a failing docker or winget does not throw, and with
# $ErrorActionPreference = 'Stop' anything a native tool writes to stderr
# (docker's progress output) becomes a terminating error. So every native call
# goes through here: errors are relaxed for the call, the exit code is read
# from $LASTEXITCODE, and the caller decides what a non-zero code means.
# ---------------------------------------------------------------------------

function Invoke-Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$File,
        [string[]]$Arguments = @(),
        [switch]$Live
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    $lines = New-Object System.Collections.ArrayList
    try {
        & $File @Arguments 2>&1 | ForEach-Object {
            $text = "$_"
            [void]$lines.Add($text)
            if ($Live) { Write-Host "   $text" }
        }
        $code = $global:LASTEXITCODE
    }
    catch {
        [void]$lines.Add($_.Exception.Message)
        $code = 1
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = [string[]]$lines.ToArray() }
}

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested in scripts/windows/Install.Tests.ps1)
# ---------------------------------------------------------------------------

function Test-N8nVersionShape { param([string]$Value) return [bool]($Value -match '^\d+\.\d+\.\d+$') }

function Test-IanaTimezone { param([string]$Value) return [bool]($Value -match '^UTC$|^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$') }

function Test-BetaKeyShape { param([string]$Value) return [bool]($Value -match '^pfb1\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') }

function Test-OperatorToken { param([string]$Value) return [bool]($Value -match '^pfo\.[A-Za-z0-9_-]{43}$') }

function Get-SuggestedTimezone {
    param([string]$WindowsId)
    if ($WindowsId -and $script:ZoneSuggestions.ContainsKey($WindowsId)) {
        return $script:ZoneSuggestions[$WindowsId]
    }
    return $null
}

# 32 random bytes as base64url with no padding: 43 characters from [A-Za-z0-9_-]
# only, so nothing the database URL or a .env line cannot carry ('@', '%', a
# space, '#'). The same alphabet INSTALL.md's Python one-liner produces.
function New-Secret {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-SecureStringPlain {
    param([System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# KEY=value lines of a .env into a hashtable. Comments and blanks are ignored.
function Read-EnvText {
    param([string]$Text)
    $values = @{}
    if (-not $Text) { return $values }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            $values[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $values
}

# Fill `KEY=` lines of the example from a hashtable, leaving every comment and
# every key not mentioned exactly as the example has it.
function Merge-EnvText {
    param([string]$ExampleText, [hashtable]$Values)
    $out = New-Object System.Collections.ArrayList
    foreach ($line in ($ExampleText -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=') {
            $key = $Matches[1]
            if ($Values.ContainsKey($key)) {
                [void]$out.Add("$key=$($Values[$key])")
                continue
            }
        }
        [void]$out.Add($line)
    }
    return ($out -join "`r`n")
}

# Which of the five situations this is (spec 2.0). Pure: facts in, name out.
#   Fresh               nothing here yet
#   OrphanedData        data on disk but no usable .env: new secrets would lock the tester out
#   Update              a complete .env
#   PartlyFilled        .env with blanks and no data yet: ask for the blanks only
#   PartlyFilledWithData  a blank SECRET beside existing data: cannot be refilled
#   NeedsVersion        only the n8n version is blank; it is not a secret, so ask
function Get-InstallState {
    param([hashtable]$EnvValues, [bool]$VolumesExist)
    $blank = @()
    foreach ($key in $script:RequiredKeys) {
        if (-not $EnvValues -or -not $EnvValues.ContainsKey($key) -or -not $EnvValues[$key]) { $blank += $key }
    }
    if ($blank.Count -eq 0) { return 'Update' }
    $allBlank = ($blank.Count -eq $script:RequiredKeys.Count)
    if ($allBlank) {
        if ($VolumesExist) { return 'OrphanedData' }
        return 'Fresh'
    }
    $secretBlank = @($blank | Where-Object { $_ -ne 'PREFLIGHT_N8N_VERSION' })
    if ($secretBlank.Count -gt 0) {
        if ($VolumesExist) { return 'PartlyFilledWithData' }
        return 'PartlyFilled'
    }
    return 'NeedsVersion'
}

function Test-HealthBody {
    param([string]$Json)
    try { $body = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    return ($null -ne $body -and $body.PSObject.Properties.Name -contains 'status' -and $body.status -eq 'ok')
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

function Write-NewTextFile {
    # Created with CreateNew on a temp name, then moved into place. Never
    # replaces a file that is there, and an interrupted run leaves no
    # half-written file.
    param([string]$Path, [string]$Text)
    if (Test-Path -LiteralPath $Path) { Stop-Install "$Path already exists; the installer does not overwrite it." }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $encoding = New-Object System.Text.UTF8Encoding $false
    $stream = [System.IO.File]::Open($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
        $bytes = $encoding.GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    try { [System.IO.File]::Move($temp, $Path) }
    catch {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Update-EnvLine {
    # Replace one KEY= line of an existing .env, through a temp file and
    # File.Replace, so nothing else in the file changes.
    param([string]$Path, [string]$Key, [string]$Value)
    $text = [System.IO.File]::ReadAllText($Path)
    $pattern = '(?m)^\s*' + [regex]::Escape($Key) + '\s*=.*$'
    $replacement = ("$Key=$Value").Replace('$', '$$')
    if ($text -match $pattern) { $new = [regex]::Replace($text, $pattern, $replacement) }
    else { $new = $text.TrimEnd() + "`r`n$Key=$Value`r`n" }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temp, $new, (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::Replace($temp, $Path, [NullString]::Value)
}

function Protect-EnvFile {
    # Grant the current user first (by SID: a Microsoft or Entra account's name
    # does not always resolve), then drop inheritance, then prove the file can
    # still be read. A tightening that leaves .env unreadable to Docker Desktop
    # is worse than none, so a failed read-back restores inheritance.
    param([string]$Path)
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $grant = Invoke-Native -File 'icacls.exe' -Arguments @($Path, '/grant:r', "*${sid}:(M)")
        if ($grant.ExitCode -ne 0) { Write-Warn 'Could not restrict who can read .env; it keeps its default access.'; return }
        $strip = Invoke-Native -File 'icacls.exe' -Arguments @($Path, '/inheritance:r')
        if ($strip.ExitCode -ne 0) { Write-Warn 'Could not restrict who can read .env; it keeps its default access.'; return }
        try { [void][System.IO.File]::ReadAllText($Path) }
        catch {
            [void](Invoke-Native -File 'icacls.exe' -Arguments @($Path, '/inheritance:e'))
            Write-Warn 'Restricting .env access broke reading it, so the restriction was undone.'
            return
        }
        Write-Ok '.env is readable by your account only.'
    }
    catch { Write-Warn 'Could not restrict who can read .env; it keeps its default access.' }
}

# ---------------------------------------------------------------------------
# Checks (spec 2.1). Each returns an object: Name, Status (ok|warn|stop), Message.
# ---------------------------------------------------------------------------

function New-Check {
    param([string]$Name, [string]$Status, [string]$Message)
    return [pscustomobject]@{ Name = $Name; Status = $Status; Message = $Message }
}

function Find-Docker {
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $candidate = Join-Path $base 'Docker\Docker\resources\bin\docker.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Find-DockerDesktop {
    # Docker Desktop installs per machine (Program Files) or per user (under
    # %LOCALAPPDATA%\Programs, which is what the installer's own "just for me"
    # option and some winget runs do). Looking only in Program Files meant a
    # per-user install was found by Find-Docker and then never started.
    $candidates = New-Object System.Collections.ArrayList
    # The most reliable guide is the docker.exe already found: it sits at
    # <install folder>\resources\bin\docker.exe, and the program is at <install folder>.
    $docker = Find-Docker
    if ($docker) {
        $bin = Split-Path -Parent $docker
        if ($bin) {
            $resources = Split-Path -Parent $bin
            if ($resources) {
                $root = Split-Path -Parent $resources
                if ($root) { [void]$candidates.Add((Join-Path $root 'Docker Desktop.exe')) }
            }
        }
    }
    if ($env:LOCALAPPDATA) {
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'))
        [void]$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\Docker\Docker\Docker Desktop.exe'))
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        [void]$candidates.Add((Join-Path $base 'Docker\Docker\Docker Desktop.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Test-WindowsVersion {
    $v = [Environment]::OSVersion.Version
    if ($v.Major -lt 10 -or ($v.Major -eq 10 -and $v.Build -lt 19041)) {
        return (New-Check 'Windows version' 'stop' "Windows 10 version 2004 (build 19041) or later is needed; this is build $($v.Build).")
    }
    return (New-Check 'Windows version' 'ok' "build $($v.Build)")
}

function Test-Architecture {
    if (-not [Environment]::Is64BitOperatingSystem) {
        return (New-Check 'Windows architecture' 'stop' 'A 64-bit version of Windows is needed.')
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        return (New-Check 'Windows architecture' 'warn' 'Windows on ARM works, but n8n runs under emulation and will be slow.')
    }
    return (New-Check 'Windows architecture' 'ok' '64-bit')
}

function Get-VirtualizationCheck {
    # Windows reports the firmware flag (VirtualizationFirmwareEnabled) as False
    # whenever a hypervisor is already running (Hyper-V, or the platform WSL2 and
    # Docker Desktop use), because the firmware flag is hidden once the hypervisor
    # has taken the feature. So a running hypervisor means virtualization IS on,
    # whatever the flag says; only "no hypervisor and the flag is off" is a
    # reason to send someone into the BIOS.
    param($Firmware, $Hypervisor)
    if ($Hypervisor -eq $true) {
        return (New-Check 'Virtualization' 'ok' 'a hypervisor is already running, so virtualization is on')
    }
    if ($Firmware -eq $false) {
        return (New-Check 'Virtualization' 'warn' 'Virtualization looks switched off in the BIOS/UEFI. Docker Desktop needs it and will say so if it cannot start.')
    }
    return (New-Check 'Virtualization' 'ok' 'no problem seen')
}

function Test-Virtualization {
    $firmware = $null
    $hypervisor = $null
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        if ($cpu) { $firmware = $cpu.VirtualizationFirmwareEnabled }
    }
    catch { }
    try {
        $system = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1
        if ($system) { $hypervisor = $system.HypervisorPresent }
    }
    catch { }
    # What this machine reported, so a wrong answer can be diagnosed afterwards.
    Write-InstallLog "virtualization: firmware flag=$firmware, hypervisor present=$hypervisor"
    return (Get-VirtualizationCheck -Firmware $firmware -Hypervisor $hypervisor)
}

function Test-DiskSpace {
    try {
        $drive = (Get-Item -LiteralPath $script:Root).PSDrive
        $freeGb = [math]::Round($drive.Free / 1GB, 1)
        if ($freeGb -lt 10) { return (New-Check 'Free disk space' 'stop' "About $freeGb GB is free on $($drive.Name):; 10 GB is needed for the images.") }
        return (New-Check 'Free disk space' 'ok' "$freeGb GB free")
    }
    catch { return (New-Check 'Free disk space' 'warn' 'Could not read free disk space.') }
}

function Test-DockerInstalled {
    if (Find-Docker) { return (New-Check 'Docker Desktop installed' 'ok' (Find-Docker)) }
    if (Find-DockerDesktop) { return (New-Check 'Docker Desktop installed' 'warn' 'Docker Desktop is installed but not on the path yet; open it once, or restart the computer.') }
    return (New-Check 'Docker Desktop installed' 'stop' 'Docker Desktop is not installed.')
}

function Get-DockerEngine {
    # { Reachable; Version; Os } from `docker version`. Never throws.
    $docker = Find-Docker
    if (-not $docker) { return [pscustomobject]@{ Reachable = $false; Version = $null; Os = $null } }
    $result = Invoke-Native -File $docker -Arguments @('version', '--format', '{{.Server.Version}} {{.Server.Os}}')
    if ($result.ExitCode -ne 0) { return [pscustomobject]@{ Reachable = $false; Version = $null; Os = $null } }
    $parts = (($result.Output -join ' ').Trim() -split '\s+')
    if ($parts.Count -lt 2) { return [pscustomobject]@{ Reachable = $false; Version = $null; Os = $null } }
    return [pscustomobject]@{ Reachable = $true; Version = $parts[0]; Os = $parts[1] }
}

function Test-DockerEngine {
    param($Engine)
    if (-not $Engine.Reachable) { return (New-Check 'Docker running' 'stop' 'Docker Desktop is not running yet.') }
    if ($Engine.Os -ne 'linux') {
        return (New-Check 'Docker running' 'stop' 'Docker is in Windows-container mode. Right-click the whale icon near the clock and choose "Switch to Linux containers".')
    }
    $major = 0
    [void][int]::TryParse(($Engine.Version -split '\.')[0], [ref]$major)
    if ($major -lt 28) {
        return (New-Check 'Docker version' 'stop' "Docker Engine $($Engine.Version) is too old; 28 or later is needed. Update Docker Desktop.")
    }
    return (New-Check 'Docker running' 'ok' "Docker Engine $($Engine.Version), Linux containers")
}

function Test-ComposePlugin {
    $docker = Find-Docker
    if (-not $docker) { return (New-Check 'Docker Compose' 'stop' 'Docker is not installed.') }
    $result = Invoke-Native -File $docker -Arguments @('compose', 'version')
    if ($result.ExitCode -ne 0) { return (New-Check 'Docker Compose' 'stop' 'Docker Compose is missing. It ships with Docker Desktop, so reinstall Docker Desktop.') }
    return (New-Check 'Docker Compose' 'ok' (($result.Output -join ' ').Trim()))
}

function Get-PortListener {
    # The process id listening on the port, or $null. No result means free; the
    # cmdlet writes an error when nothing listens, which must not be a crash.
    param([int]$Port)
    try {
        $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listener) { return [int]$listener.OwningProcess }
    }
    catch { }
    return $null
}

function Test-StackRunning {
    # Whether THIS folder's Preflight is up, which is what makes port 8000
    # being busy the update path rather than a conflict.
    $docker = Find-Docker
    if (-not $docker) { return $false }
    $result = Invoke-Native -File $docker -Arguments @('compose', '--project-directory', $script:Root, 'ps', '--status', 'running', '--services')
    if ($result.ExitCode -ne 0) { return $false }
    return (@($result.Output | Where-Object { $_ -eq 'api' }).Count -gt 0)
}

function Test-Port {
    param([bool]$StackRunning)
    $owner = Get-PortListener -Port $script:ApiPort
    if ($null -eq $owner) { return (New-Check "Port $($script:ApiPort)" 'ok' 'free') }
    if ($StackRunning) { return (New-Check "Port $($script:ApiPort)" 'ok' 'in use by this Preflight, which is the update path') }
    $name = ''
    try { $name = " ($((Get-Process -Id $owner -ErrorAction Stop).ProcessName))" } catch { }
    return (New-Check "Port $($script:ApiPort)" 'stop' "Something else is using port $($script:ApiPort) (process $owner$name). Close it and run this again.")
}

function Test-Registry {
    param([string]$HostName)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        [void](Invoke-WebRequest -Uri "https://$HostName/v2/" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop)
        return (New-Check "Reach $HostName" 'ok' 'reachable')
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($response -and ([int]$response.StatusCode -in 200, 401, 403)) { return (New-Check "Reach $HostName" 'ok' 'reachable') }
        return (New-Check "Reach $HostName" 'warn' "Could not reach $HostName. A company proxy or firewall may be in the way; the download will say if it is a real problem.")
    }
    catch { return (New-Check "Reach $HostName" 'warn' "Could not reach $HostName. A company proxy or firewall may be in the way; the download will say if it is a real problem.") }
}

function Test-NotElevated {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            return (New-Check 'Running as administrator' 'warn' 'You are running as administrator. That is not needed and can leave files owned oddly; a normal window is better.')
        }
    }
    catch { }
    return (New-Check 'Running as administrator' 'ok' 'no')
}

function Invoke-Checks {
    # Read-only. Returns every check; nothing is changed.
    $checks = New-Object System.Collections.ArrayList
    [void]$checks.Add((Test-WindowsVersion))
    [void]$checks.Add((Test-Architecture))
    [void]$checks.Add((Test-Virtualization))
    [void]$checks.Add((Test-DiskSpace))
    $installed = Test-DockerInstalled
    [void]$checks.Add($installed)
    $running = $false
    if ($installed.Status -ne 'stop') {
        $engine = Get-DockerEngine
        $engineCheck = Test-DockerEngine -Engine $engine
        [void]$checks.Add($engineCheck)
        if ($engineCheck.Status -eq 'ok') {
            [void]$checks.Add((Test-ComposePlugin))
            $running = Test-StackRunning
        }
    }
    [void]$checks.Add((Test-Port -StackRunning $running))
    foreach ($h in @('ghcr.io', 'docker.n8n.io', 'registry-1.docker.io')) { [void]$checks.Add((Test-Registry -HostName $h)) }
    [void]$checks.Add((Test-NotElevated))
    return $checks
}

function Show-Checks {
    param($Checks)
    foreach ($c in $Checks) {
        switch ($c.Status) {
            'ok' { Write-Ok "$($c.Name): $($c.Message)" }
            'warn' { Write-Warn "$($c.Name): $($c.Message)" }
            default { Write-Problem "$($c.Name): $($c.Message)" }
        }
    }
}

# ---------------------------------------------------------------------------
# Docker Desktop
# ---------------------------------------------------------------------------

function Confirm-Yes {
    param([string]$Question)
    $answer = Read-Host "$Question (y/n)"
    return ($answer -match '^\s*[yY]')
}

function Install-DockerDesktop {
    Write-Step 'Docker Desktop is not installed'
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Note 'Download and install Docker Desktop from https://www.docker.com/products/docker-desktop/ then run this again.'
        Write-Note 'Open Docker Desktop once after installing and accept its terms.'
        Stop-Install 'Install Docker Desktop first, then double-click install.cmd again.'
    }
    Write-Note 'I can install it for you with Windows Package Manager. It is about 600 MB, needs administrator'
    Write-Note 'permission (Windows will ask), and may need a restart.'
    if (-not (Confirm-Yes 'Install Docker Desktop now?')) {
        Write-Note 'Download it from https://www.docker.com/products/docker-desktop/ then run this again.'
        Stop-Install 'Docker Desktop is needed. Install it, then double-click install.cmd again.'
    }
    $result = Invoke-Native -File $winget.Source -Arguments @('install', '-e', '--id', 'Docker.DockerDesktop', '--accept-package-agreements', '--accept-source-agreements') -Live
    if ($result.ExitCode -ne 0) {
        Write-Note 'The automatic install did not finish. Download it from https://www.docker.com/products/docker-desktop/ instead.'
        Stop-Install "The Docker Desktop install failed (exit code $($result.ExitCode))."
    }
    Write-Ok 'Docker Desktop is installed.'
    Write-Note 'Now: restart your computer, open Docker Desktop once and accept its terms (it may install'
    Write-Note 'a Windows feature and ask for one more restart), then double-click install.cmd again.'
    return
}

function Start-DockerDesktop {
    # $true once the engine answers. Otherwise $false, with the reason in
    # $script:DockerStartFailure ('not-found', 'would-not-start' or 'timeout')
    # so the caller says what actually happened. It used to say "did not start in
    # 3 minutes" when it had not tried at all.
    $script:DockerStartFailure = $null
    $exe = Find-DockerDesktop
    if (-not $exe) { $script:DockerStartFailure = 'not-found'; return $false }
    Write-Note 'Starting Docker Desktop. If a window asks you to accept terms or allow changes, do that.'
    try { Start-Process -FilePath $exe | Out-Null }
    catch {
        $script:DockerStartFailure = 'would-not-start'
        $script:DockerStartError = $_.Exception.Message
        return $false
    }
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $engine = Get-DockerEngine
        if ($engine.Reachable) { return $true }
        Write-Host -NoNewline '.'
    }
    Write-Host ''
    $script:DockerStartFailure = 'timeout'
    return $false
}

function Get-DockerStartMessage {
    # What to tell the person when Docker Desktop could not be started.
    param([string]$Failure, [bool]$VirtualizationOff, [string]$Detail)
    $open = 'Open Docker Desktop yourself from the Start menu, wait for the whale icon to settle, then run this again.'
    $text = switch ($Failure) {
        'not-found' { "I could not find the Docker Desktop program to start it. $open" }
        'would-not-start' { "Windows would not start Docker Desktop ($Detail). $open" }
        default { "Docker Desktop did not start within 3 minutes. $open" }
    }
    if ($VirtualizationOff) {
        $text += ' The check above said virtualization looks switched off in the BIOS/UEFI; Docker Desktop cannot run until it is on (look for Intel VT-x, AMD-V or SVM in the BIOS settings).'
    }
    return $text
}

# ---------------------------------------------------------------------------
# Compose
# ---------------------------------------------------------------------------

function Invoke-Compose {
    param([string[]]$Arguments, [switch]$Live)
    $docker = Find-Docker
    if (-not $docker) { Stop-Install 'Docker was not found.' }
    $all = @('compose', '--project-directory', $script:Root) + $Arguments
    return (Invoke-Native -File $docker -Arguments $all -Live:$Live)
}

function Get-PreflightVolumes {
    $docker = Find-Docker
    if (-not $docker) { return @() }
    $result = Invoke-Native -File $docker -Arguments @('volume', 'ls', '--format', '{{.Name}}', '--filter', "name=$($script:ProjectPrefix)")
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Output | Where-Object { $_ -like "$($script:ProjectPrefix)*" })
}

function Test-N8nVersionExists {
    # $true = exists, $false = the registry says no, $null = could not ask.
    param([string]$Version)
    $docker = Find-Docker
    if (-not $docker) { return $null }
    $result = Invoke-Native -File $docker -Arguments @('manifest', 'inspect', "docker.n8n.io/n8nio/n8n:$Version")
    if ($result.ExitCode -eq 0) { return $true }
    $text = ($result.Output -join ' ')
    if ($text -match 'no such manifest|not found|manifest unknown|MANIFEST_UNKNOWN') { return $false }
    return $null
}

function Wait-Ready {
    # Up to 5 minutes for /health at 127.0.0.1 to say "status":"ok". 127.0.0.1,
    # not localhost: compose binds IPv4 loopback only and 5.1 tries ::1 first.
    # A 200 alone is not ready; the endpoint answers 200 while "degraded".
    param([int]$Seconds = 300)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $deadline = (Get-Date).AddSeconds($Seconds)
    $degradedSince = $null
    $lastBody = $null
    while ((Get-Date) -lt $deadline) {
        $body = $null
        try {
            $response = Invoke-WebRequest -Uri $script:HealthUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $body = [string]$response.Content
        }
        catch { $body = $null }
        if ($body) {
            if (Test-HealthBody $body) { Write-Host ''; return $true }
            $lastBody = $body
            if (-not $degradedSince) { $degradedSince = Get-Date }
            if (((Get-Date) - $degradedSince).TotalSeconds -gt 60) { break }
        }
        else { $degradedSince = $null }
        Write-Host -NoNewline '.'
        Start-Sleep -Seconds 3
    }
    Write-Host ''
    if ($lastBody) {
        Write-Warn 'Preflight is running but reports a problem:'
        try {
            $parsed = $lastBody | ConvertFrom-Json
            foreach ($field in 'status', 'database', 'schema') {
                if ($parsed.PSObject.Properties.Name -contains $field) { Write-Note "  $field = $($parsed.$field | ConvertTo-Json -Compress)" }
            }
        }
        catch { }
        Write-Note 'A wrong database password (the database keeps the one it was first created with) looks like this.'
    }
    else {
        $logs = Invoke-Compose -Arguments @('logs', '--tail', '30', 'api')
        Write-Warn 'Preflight did not answer in time. The last lines of its log:'
        foreach ($line in $logs.Output) { Write-Note "  $line" }
    }
    Write-Note 'Copy the text above into an email to Logan.'
    return $false
}

function Invoke-Backup {
    # pg_dump inside the container, then docker compose cp: the way INSTALL.md
    # does it, and it avoids PowerShell re-encoding a SQL dump on the way out.
    $folder = Join-Path $script:Root 'backups'
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder) }
    $name = 'preflight-backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.sql'
    $target = Join-Path $folder $name
    $dump = Invoke-Compose -Arguments @('exec', '-T', 'postgres', 'pg_dump', '-U', 'preflight', '-f', '/tmp/preflight-backup.sql', 'preflight')
    if ($dump.ExitCode -ne 0) { Stop-Install 'The backup before updating failed, so nothing was changed. Check that Preflight is running (docker compose ps), then run this again.' }
    $copy = Invoke-Compose -Arguments @('cp', 'postgres:/tmp/preflight-backup.sql', $target)
    if ($copy.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -eq 0) {
        Stop-Install 'The backup before updating came out empty, so nothing was changed.'
    }
    return $target
}

function Get-OperatorToken {
    # Captured into a variable, never left on the success stream. Retried
    # because the file only exists once the API has booted.
    $deadline = (Get-Date).AddSeconds(30)
    while ($true) {
        $result = Invoke-Compose -Arguments @('exec', '-T', '-u', 'app', 'api', 'cat', '/preflight-state/api-token')
        if ($result.ExitCode -eq 0) {
            $token = (($result.Output -join '').Trim())
            if (Test-OperatorToken $token) { return $token }
        }
        if ((Get-Date) -gt $deadline) { return $null }
        Start-Sleep -Seconds 2
    }
}

function Set-ClipboardText {
    param([string]$Text)
    try { Set-Clipboard -Value $Text -ErrorAction Stop; return $true } catch { }
    try { $Text | & clip.exe; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------

function Read-N8nVersion {
    while ($true) {
        $value = (Read-Host 'Your n8n version, exactly (n8n: Help > About), for example 2.44.6').Trim()
        if (-not (Test-N8nVersionShape $value)) { Write-Warn 'That is not three numbers like 2.44.6. Please try again.'; continue }
        $exists = Test-N8nVersionExists -Version $value
        if ($exists -eq $false) { Write-Warn "n8n has no release $value. Check Help > About in n8n and try again."; continue }
        if ($null -eq $exists) { Write-Warn 'Could not confirm that release with the registry; continuing. The download will say if it does not exist.' }
        return $value
    }
}

function Read-Timezone {
    $windowsId = ''
    try { $windowsId = [System.TimeZoneInfo]::Local.Id } catch { }
    $suggestion = Get-SuggestedTimezone -WindowsId $windowsId
    Write-Note "Your Windows time zone is '$windowsId'."
    Write-Note 'Preflight needs the zone your n8n uses (its GENERIC_TIMEZONE), written like America/Edmonton or UTC.'
    while ($true) {
        $prompt = 'Time zone'
        if ($suggestion) { $prompt += " [press Enter for $suggestion]" }
        $value = (Read-Host $prompt).Trim()
        if (-not $value -and $suggestion) { $value = $suggestion }
        if (Test-IanaTimezone $value) { return $value }
        Write-Warn 'That does not look like a time zone name such as America/Edmonton or UTC.'
    }
}

function Read-BetaKey {
    while ($true) {
        $secure = Read-Host 'Your beta key (starts pfb1.; press Enter to enter it in Preflight instead)' -AsSecureString
        $plain = ConvertFrom-SecureStringPlain $secure
        if (-not $plain) { return '' }
        $plain = $plain.Trim()
        if (Test-BetaKeyShape $plain) { Register-Secret $plain; return $plain }
        Write-Warn 'That is not shaped like a beta key (pfb1.something.something). Check the invitation email.'
    }
}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

function Invoke-Install {
    Write-InstallLog "install.ps1 started in $($script:Root)"
    Write-Host 'Preflight installer'
    Write-Host 'Safe to run again at any point. It never deletes your data or changes a secret in use.'

    Write-Step 'Checking this computer'
    $checks = Invoke-Checks
    Show-Checks $checks
    $dockerMissing = @($checks | Where-Object { $_.Name -eq 'Docker Desktop installed' -and $_.Status -eq 'stop' }).Count -gt 0
    if ($dockerMissing) { Install-DockerDesktop; return 0 }

    $engineDown = @($checks | Where-Object { $_.Name -eq 'Docker running' -and $_.Status -eq 'stop' -and $_.Message -like '*not running*' }).Count -gt 0
    if ($engineDown) {
        if (Confirm-Yes 'Docker Desktop is not running. Start it now?') {
            if (Start-DockerDesktop) { Write-Ok 'Docker is running.'; $checks = Invoke-Checks; Show-Checks $checks }
            else {
                $virtualizationOff = @($checks | Where-Object { $_.Name -eq 'Virtualization' -and $_.Status -eq 'warn' }).Count -gt 0
                Stop-Install (Get-DockerStartMessage -Failure $script:DockerStartFailure -VirtualizationOff $virtualizationOff -Detail $script:DockerStartError)
            }
        }
        else { Stop-Install 'Start Docker Desktop, then run this again.' }
    }
    $stops = @($checks | Where-Object { $_.Status -eq 'stop' })
    if ($stops.Count -gt 0) { Stop-Install ($stops[0].Message) }

    $composePath = Join-Path $script:Root 'docker-compose.yml'
    if (-not (Test-Path -LiteralPath $composePath)) { Stop-Install 'docker-compose.yml is not next to this script. Run it from the folder you downloaded, with everything extracted.' }

    $envPath = Join-Path $script:Root '.env'
    $examplePath = Join-Path $script:Root '.env.example'
    $existing = @{}
    if (Test-Path -LiteralPath $envPath) { $existing = Read-EnvText ([System.IO.File]::ReadAllText($envPath)) }
    $volumes = @(Get-PreflightVolumes)
    $state = Get-InstallState -EnvValues $existing -VolumesExist ($volumes.Count -gt 0)
    Write-InstallLog "state $state ($($volumes.Count) volume(s))"

    switch ($state) {
        'OrphanedData' {
            Stop-Install ("Found Preflight data from an earlier install on this computer, but no complete .env. New secrets would lock you out of that data. " +
                "Restore your old .env from a backup and run this again. To start over and DELETE that data, run 'docker compose down -v' yourself; this installer never deletes data.")
        }
        'PartlyFilledWithData' {
            Stop-Install ("Your .env is missing a secret and Preflight data already exists. A secret cannot be refilled safely against existing data. " +
                "Restore the .env you used before, or ask Logan for help.")
        }
    }

    $values = @{}
    if ($state -eq 'Fresh' -or $state -eq 'PartlyFilled') {
        Write-Step 'A few questions'
        foreach ($key in 'PREFLIGHT_SECRET', 'POSTGRES_PASSWORD') {
            if (-not ($existing.ContainsKey($key) -and $existing[$key])) {
                $value = New-Secret
                Register-Secret $value
                $values[$key] = $value
            }
        }
        if (-not ($existing.ContainsKey('PREFLIGHT_N8N_VERSION') -and $existing['PREFLIGHT_N8N_VERSION'])) { $values['PREFLIGHT_N8N_VERSION'] = Read-N8nVersion }
        # Ask for the zone unless the .env already holds one other than the
        # example's default, and for the key unless it already holds one.
        $zone = ''
        if ($existing.ContainsKey('PREFLIGHT_TIMEZONE')) { $zone = $existing['PREFLIGHT_TIMEZONE'] }
        if (-not $zone -or $zone -eq 'UTC') { $values['PREFLIGHT_TIMEZONE'] = Read-Timezone }
        if (-not ($existing.ContainsKey('PREFLIGHT_BETA_KEY') -and $existing['PREFLIGHT_BETA_KEY'])) {
            $key = Read-BetaKey
            if ($key) { $values['PREFLIGHT_BETA_KEY'] = $key }
        }
        if ($state -eq 'Fresh' -and -not (Test-Path -LiteralPath $envPath)) {
            if (-not (Test-Path -LiteralPath $examplePath)) { Stop-Install '.env.example is missing from this folder; extract the whole download.' }
            $text = Merge-EnvText ([System.IO.File]::ReadAllText($examplePath)) $values
            Write-NewTextFile -Path $envPath -Text $text
        }
        else {
            foreach ($k in $values.Keys) { Update-EnvLine -Path $envPath -Key $k -Value $values[$k] }
        }
        Write-Ok '.env written. It holds your secrets: keep it, and do not email it.'
        Protect-EnvFile -Path $envPath
        Write-Note 'PREFLIGHT_SECRET encrypts the n8n keys you register. Never change it once you have registered anything.'
    }
    elseif ($state -eq 'NeedsVersion') {
        Write-Step 'One missing value'
        $version = Read-N8nVersion
        Update-EnvLine -Path $envPath -Key 'PREFLIGHT_N8N_VERSION' -Value $version
        Write-Ok 'n8n version saved.'
    }
    elseif ($state -eq 'Update') {
        Write-Step 'An existing install'
        Write-Ok 'Found your .env; keeping it as it is.'
        Register-Secret $existing['PREFLIGHT_SECRET']
        Register-Secret $existing['POSTGRES_PASSWORD']
        $current = $existing['PREFLIGHT_N8N_VERSION']
        if (Confirm-Yes "Your n8n version is set to $current. Change it?") {
            Update-EnvLine -Path $envPath -Key 'PREFLIGHT_N8N_VERSION' -Value (Read-N8nVersion)
        }
        $releases = Join-Path $script:Root 'RELEASES.md'
        if (Test-Path -LiteralPath $releases) {
            Write-Note 'What changed in this version (the full list is in RELEASES.md):'
            Get-Content -LiteralPath $releases -TotalCount 30 | ForEach-Object { Write-Note "  $_" }
        }
        if (-not (Confirm-Yes 'Update now? A backup of your data is taken first.')) { Stop-Install 'Nothing was changed.' }
        if ($volumes -contains "$($script:ProjectPrefix)postgres-data") {
            Write-Step 'Backing up your data'
            if (-not (Test-StackRunning)) { $up = Invoke-Compose -Arguments @('up', '-d', 'postgres') -Live; if ($up.ExitCode -ne 0) { Stop-Install 'Could not start the database to back it up.' }; Start-Sleep -Seconds 10 }
            $saved = Invoke-Backup
            Write-Ok "Backup saved to $saved (it holds your data in clear; keep it private)."
        }
    }

    Write-Step 'Downloading and starting Preflight (the first time takes a few minutes)'
    $pull = Invoke-Compose -Arguments @('pull') -Live
    if ($pull.ExitCode -ne 0) { Stop-Install "Downloading failed (exit code $($pull.ExitCode)). Check your internet connection and that Docker Desktop is running, then run this again." }
    $up = Invoke-Compose -Arguments @('up', '-d') -Live
    if ($up.ExitCode -ne 0) { Stop-Install "Starting failed (exit code $($up.ExitCode)). The messages above say why; a missing value in .env is the usual cause." }

    Write-Step 'Waiting for Preflight to be ready'
    if (-not (Wait-Ready)) { Stop-Install 'Preflight did not become ready.' }
    Write-Ok 'Preflight is ready.'

    Write-Step 'Signing in'
    $token = Get-OperatorToken
    if ($token) {
        Register-Secret $token
        $copied = Set-ClipboardText -Text $token
        if ($copied) {
            Write-Ok 'Your operator token is on the clipboard. Paste it into the page that opens.'
            Write-Note 'It only works on this computer. If other people use this PC, clear Windows clipboard history (Win+V).'
        }
        else { Write-Warn 'Could not use the clipboard. Print the token with:  docker compose exec -u app api cat /preflight-state/api-token' }
    }
    else { Write-Warn 'Could not read the operator token yet. Print it with:  docker compose exec -u app api cat /preflight-state/api-token' }
    Start-Process 'http://localhost:8000'
    Write-Note 'If no beta key was entered, the bar at the top says Read-only; click it and paste your key.'
    Write-Note 'Next: register your n8n on the Instances page. INSTALL.md, step 5, has the address table.'
    return 0
}

function Invoke-Main {
    $code = 0
    try {
        if ($Check) {
            Write-Step 'Checking this computer (read-only)'
            $checks = Invoke-Checks
            Show-Checks $checks
            if (@($checks | Where-Object { $_.Status -eq 'stop' }).Count -gt 0) { $code = 1 }
        }
        else { $code = Invoke-Install }
    }
    catch {
        Write-Host ''
        if ($_.Exception.Data['InstallStop']) {
            Write-Problem $_.Exception.Message
            Write-Note 'Run install.cmd again once that is fixed; it is safe to run again.'
        }
        else {
            Write-Problem ("Something unexpected went wrong: " + (Protect-Text $_.Exception.Message))
            Write-Note 'Run install.cmd again; it is safe to run again. If it keeps happening, email Logan the lines above.'
        }
        $code = 1
    }
    return $code
}

# Tests dot-source this file to reach the functions without running anything.
if ($env:PREFLIGHT_INSTALL_LIB -ne '1') {
    $exitCode = Invoke-Main
    exit $exitCode
}
