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

# The Compose project the install's docker-compose.yml names. Commands the
# installer tells a person to type name it with -p, because a plain
# "docker compose down" reads docker-compose.yml, which refuses to load
# without the .env whose absence is usually why the command is needed.
$script:ProjectName = 'preflight-selfhost'
$script:ProjectPrefix = "$($script:ProjectName)_"
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

function Test-RunningFromArchive {
    # $true when the installer is running from inside a ZIP that was opened
    # rather than extracted. Windows Explorer (and 7-Zip, WinRAR) copy the
    # files to a temporary folder for that, and delete it later: the .env
    # written there, holding the secrets, goes with it, and the next install
    # finds the data with no key to it. Found on the first real run, 29 Oct.
    # The test is the shape of those folder names, wherever they are: the
    # temp folder can be given in its short 8.3 form (C:\Users\MICRO~1\...)
    # while the script's own path is the long one, so a "starts with %TEMP%"
    # test would miss it. Names of this shape are not ones a person picks.
    param([string]$Path)
    if (-not $Path) { return $false }
    $full = $Path.TrimEnd('\', '/') + '\'
    # Explorer: <guid>_<name>.zip.<3 chars>\ ; 7-Zip: 7zO<letters>\ ; WinRAR: Rar$EX<nn>.<nnnn>\
    return [bool]($full -match '(?i)\\[^\\]*\.zip\.[^\\]+\\|\\7zO[^\\]*\\|\\Rar\$EX[^\\]*\\')
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
    # [ \t] and [^\r\n], not \s and .: \s crosses line breaks (eating a blank
    # line above the key) and . keeps the \r of a CRLF line.
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[^\r\n]*'
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

function Test-PortFree {
    # Whether 127.0.0.1:<port> can be bound: the same thing Docker will try.
    # Asking Get-NetTCPConnection for listeners is not enough. Docker Desktop's
    # com.docker.backend holds a published port in a state that cmdlet reports
    # as blank rather than Listen, so a port another Preflight held read as
    # free, and the install failed later at "port is already allocated"
    # (Logan's run, 31 Oct).
    param([int]$Port)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Port
        $listener.Start()
        return $true
    }
    catch { return $false }
    finally { if ($listener) { try { $listener.Stop() } catch { } } }
}

function Get-PortOwner {
    # Who holds the port, in words: a Docker container's name when one
    # publishes it, otherwise the process. '' when it cannot be told.
    param([int]$Port)
    $docker = Find-Docker
    if ($docker) {
        $result = Invoke-Native -File $docker -Arguments @('ps', '--filter', "publish=$Port", '--format', '{{.Names}}')
        $names = @($result.Output | Where-Object { $_ -and $_.Trim() })
        if ($result.ExitCode -eq 0 -and $names.Count) { return "the Docker container $($names[0])" }
    }
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) { return "process $($conn.OwningProcess) ($((Get-Process -Id $conn.OwningProcess -ErrorAction Stop).ProcessName))" }
    }
    catch { }
    return ''
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
    # Untyped on purpose: a [string] parameter turns $null into '', and the
    # owner would then never be looked up.
    param([bool]$StackRunning, $Owner = $null, $Free = $null)
    if ($null -eq $Free) { $Free = Test-PortFree -Port $script:ApiPort }
    if ($Free) { return (New-Check "Port $($script:ApiPort)" 'ok' 'free') }
    if ($StackRunning) { return (New-Check "Port $($script:ApiPort)" 'ok' 'in use by this Preflight, which is the update path') }
    if ($null -eq $Owner) { $Owner = Get-PortOwner -Port $script:ApiPort }
    $who = if ($Owner) { $Owner } else { 'another program' }
    $fix = if ($Owner -like 'the Docker container *') { "Stop it with  docker stop $($Owner.Substring('the Docker container '.Length))  and run this again." } else { 'Close it and run this again.' }
    return (New-Check "Port $($script:ApiPort)" 'stop' "Port $($script:ApiPort) is already in use by $who, and Preflight needs it. $fix")
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

# The replay sandbox's own volume: n8n's scratch SQLite database, holding
# nothing a person made (replay workflows are deleted after each replay, and the
# sandbox's owner credential lives in preflight-state). It is removed when the
# sandbox's n8n version changes, because n8n starts on a database another
# version migrated without a word (measured: 2.33.7 ran on a database 2.35.7
# had migrated), and a replay there is a verdict from a sandbox in an untested
# state.
#
# Removal is by exact name only, never through the name filter
# Get-PreflightVolumes uses: that filter also matches postgres-data and
# preflight-state, which hold everything the person has.
# \z, not $: $ also matches before a trailing newline.
$script:SandboxVolumePattern = '^preflight-selfhost_n8n-sandbox(-[2-4])?-data\z'

function Get-SandboxVolumeName {
    param([int]$Slot = 1)
    if ($Slot -eq 1) { return "$($script:ProjectPrefix)n8n-sandbox-data" }
    if ($Slot -ge 2 -and $Slot -le 4) { return "$($script:ProjectPrefix)n8n-sandbox-$Slot-data" }
    throw "There is no sandbox slot $Slot."
}

function Get-SandboxServiceName {
    param([int]$Slot = 1)
    if ($Slot -eq 1) { return 'n8n-sandbox' }
    if ($Slot -ge 2 -and $Slot -le 4) { return "n8n-sandbox-$Slot" }
    throw "There is no sandbox slot $Slot."
}

function Test-SandboxVolumeName {
    # The last check before a volume is removed: $true only for a sandbox's
    # own volume, spelled exactly.
    param([string]$Name)
    return [bool]($Name -cmatch $script:SandboxVolumePattern)
}

function Remove-SandboxVolume {
    # Stop and remove the slot's container, then its volume. Docker refuses to
    # remove a volume a container still holds, so the order matters. A volume
    # that is not there is not an error: nothing to reset. Returns $true when
    # the slot will start fresh.
    param([int]$Slot = 1)
    $volume = Get-SandboxVolumeName -Slot $Slot
    if (-not (Test-SandboxVolumeName $volume)) { Stop-Install "Refusing to remove ${volume}: it is not a sandbox volume." }
    $docker = Find-Docker
    if (-not $docker) { Stop-Install 'Docker was not found.' }
    $exists = Invoke-Native -File $docker -Arguments @('volume', 'inspect', $volume)
    if ($exists.ExitCode -ne 0) { Write-InstallLog "sandbox volume $volume not present; nothing to reset"; return $true }
    $service = Get-SandboxServiceName -Slot $Slot
    $rm = Invoke-Compose -Arguments @('rm', '-s', '-f', $service)
    if ($rm.ExitCode -ne 0) { Stop-Install "Could not stop the sandbox ($service) to reset it. Nothing was deleted. Check that Docker Desktop is running, then run this again." }
    $gone = Invoke-Native -File $docker -Arguments @('volume', 'rm', $volume)
    if ($gone.ExitCode -ne 0) { Stop-Install "Could not remove the sandbox's scratch database ($volume). Your .env was not changed. Run this again; if it keeps failing, run  docker volume rm $volume  yourself first." }
    Write-Ok "Reset the sandbox's scratch database ($volume)."
    return $true
}

# ---------------------------------------------------------------------------
# Sandbox slots (pure, unit-tested)
# ---------------------------------------------------------------------------
# Up to four sandboxes, one n8n version each. Slot 1 is PREFLIGHT_N8N_VERSION
# and always on; slots 2 to 4 are PREFLIGHT_N8N_VERSION_2 to _4, each turned on
# by its profile (sandbox-2 to -4) in COMPOSE_PROFILES.

$script:SlotKeys = @('PREFLIGHT_N8N_VERSION', 'PREFLIGHT_N8N_VERSION_2', 'PREFLIGHT_N8N_VERSION_3', 'PREFLIGHT_N8N_VERSION_4')
$script:MaxSlots = 4

function Get-SandboxSlots {
    # The four slot versions from .env values, '' for an empty slot.
    param([hashtable]$EnvValues)
    $slots = @('', '', '', '')
    for ($i = 0; $i -lt $script:MaxSlots; $i++) {
        $key = $script:SlotKeys[$i]
        if ($EnvValues -and $EnvValues.ContainsKey($key) -and $EnvValues[$key]) { $slots[$i] = [string]$EnvValues[$key] }
    }
    return , $slots
}

function ConvertTo-VersionList {
    # "2.44.6, 2.40.3,2.44.6" -> 2.44.6, 2.40.3: trimmed, empty parts dropped,
    # duplicates dropped, first-seen order kept.
    param([string]$Text)
    $out = New-Object System.Collections.ArrayList
    if (-not $Text) { return , @() }
    foreach ($part in ($Text -split ',')) {
        $value = $part.Trim()
        if ($value -and -not $out.Contains($value)) { [void]$out.Add($value) }
    }
    return , @($out.ToArray())
}

function Resolve-SandboxSlots {
    # Assign versions to slots by identity, never by typing order: a version
    # already in a slot stays there, a new one takes the lowest empty slot, and
    # slot 1 changes only when its version leaves the list. Typing the same
    # versions in another order changes nothing, so nothing is reset.
    # Returns the four slot versions; throws (Stop-Install) on more than four.
    param([string[]]$Current, [string[]]$Wanted)
    if (-not $Wanted -or $Wanted.Count -eq 0) { Stop-Install 'At least one n8n version is needed: the one your instances run.' }
    if ($Wanted.Count -gt $script:MaxSlots) { Stop-Install "Preflight runs at most $($script:MaxSlots) sandboxes. Pick the $($script:MaxSlots) versions you need most." }
    $next = @('', '', '', '')
    for ($i = 0; $i -lt $script:MaxSlots; $i++) {
        if ($Current[$i] -and ($Wanted -contains $Current[$i])) { $next[$i] = $Current[$i] }
    }
    foreach ($version in $Wanted) {
        if ($next -contains $version) { continue }
        for ($i = 0; $i -lt $script:MaxSlots; $i++) {
            if (-not $next[$i]) { $next[$i] = $version; break }
        }
    }
    if (-not $next[0]) {
        # Slot 1 is required. Its version left the list and no new version took
        # its place, so the lowest remaining slot moves into it.
        for ($i = 1; $i -lt $script:MaxSlots; $i++) {
            if ($next[$i]) { $next[0] = $next[$i]; $next[$i] = ''; break }
        }
    }
    return , $next
}

function Get-ComposeProfiles {
    # COMPOSE_PROFILES for the occupied optional slots, e.g. sandbox-2,sandbox-4.
    param([string[]]$Slots)
    $profiles = @()
    for ($i = 1; $i -lt $script:MaxSlots; $i++) {
        if ($Slots[$i]) { $profiles += "sandbox-$($i + 1)" }
    }
    return ($profiles -join ',')
}

function Get-ChangedSlots {
    # Slot numbers (1-4) whose version changed, were switched off, or were
    # newly filled: any of them may hold a scratch database another version
    # made (a slot emptied by hand keeps its volume), so each must go before
    # it starts again. The caller keeps only the slots that have a volume.
    param([string[]]$Old, [string[]]$New)
    $changed = @()
    for ($i = 0; $i -lt $script:MaxSlots; $i++) {
        if ([string]$Old[$i] -ne [string]$New[$i]) { $changed += ($i + 1) }
    }
    return , $changed
}

function Get-RunningSlots {
    # The slots Compose will actually start: slot 1, and each other slot with
    # a version AND its profile in COMPOSE_PROFILES (or COMPOSE_PROFILES=*).
    # What the installer waits for, so a hand edit that set a version without
    # its profile is reported rather than waited on for five minutes.
    param([string[]]$Slots, [string]$Profiles)
    $on = @('', '', '', '')
    $enabled = @(([string]$Profiles -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    for ($i = 0; $i -lt $script:MaxSlots; $i++) {
        if (-not $Slots[$i]) { continue }
        if ($i -eq 0 -or $enabled -contains '*' -or $enabled -contains "sandbox-$($i + 1)") { $on[$i] = $Slots[$i] }
    }
    return , $on
}

function Get-SandboxMemoryGB {
    # The worst case, in GB: at most two sandboxes run a workflow at once
    # (Preflight allows two executions across all sandboxes), each up to its
    # 1 GB limit; the rest idle, measured at about 0.45 GB; Preflight itself
    # about 0.5 GB.
    param([int]$Count)
    $busy = [Math]::Min($Count, 2)
    $idle = [Math]::Max($Count - 2, 0)
    return [Math]::Round($busy * 1.0 + $idle * 0.45 + 0.5, 1)
}

function Format-SandboxSlots {
    param([string[]]$Slots, [string]$Target)
    $lines = @()
    for ($i = 0; $i -lt $script:MaxSlots; $i++) {
        if (-not $Slots[$i]) { continue }
        $note = if ($Target -and $Slots[$i] -eq $Target) { '   (upgrade target)' } else { '' }
        $lines += ("  slot {0}  {1}{2}" -f ($i + 1), $Slots[$i], $note)
    }
    return $lines
}

function Confirm-SandboxReset {
    # Asked once, naming every volume, before anything is deleted. Returns
    # $true with nothing asked when none of the slots has a volume yet.
    param([int[]]$Slots, [string[]]$Volumes, [string[]]$Old, [string[]]$New)
    $doomed = @()
    foreach ($slot in $Slots) {
        $volume = Get-SandboxVolumeName -Slot $slot
        if ($Volumes -contains $volume) { $doomed += $slot }
    }
    if ($doomed.Count -eq 0) { return $true }
    foreach ($slot in $doomed) {
        $was = [string]$Old[$slot - 1]
        $now = [string]$New[$slot - 1]
        $what = if (-not $was) { "is being set to n8n $now" } elseif (-not $now) { "(n8n $was) is being switched off" } else { "changes from n8n $was to $now" }
        Write-Note "Sandbox slot $slot $what, so its scratch database ($(Get-SandboxVolumeName -Slot $slot)) is deleted."
    }
    Write-Note 'A sandbox scratch database holds nothing you made: no recordings, no workflow history, no settings. Those are kept.'
    Write-Note 'n8n would otherwise start on a database another version had changed, and say nothing.'
    return (Confirm-Yes 'Delete and go ahead?')
}

function Read-SandboxVersions {
    # The two questions. Returns the wanted versions, slot-1 candidate first,
    # and the upgrade target (or '').
    param([string[]]$Current)
    $currentRun = @()
    foreach ($v in $Current) { if ($v) { $currentRun += $v } }
    while ($true) {
        $hint = if ($currentRun.Count) { " Now: $($currentRun -join ', ')." } else { '' }
        # In quotes: Read-Host returns $null when there is no console input.
        $answer = "$(Read-Host "Which n8n versions do your instances run? One or more, separated by commas, for example 2.44.6, 2.40.3 (n8n: Help > About).$hint")"
        if (-not $answer.Trim() -and $currentRun.Count) { $run = $currentRun } else { $run = ConvertTo-VersionList $answer }
        if ($run.Count -eq 0) { Write-Warn 'At least one version is needed.'; continue }
        $bad = @($run | Where-Object { -not (Test-N8nVersionShape $_) })
        if ($bad.Count) { Write-Warn "$($bad -join ', ') is not three numbers like 2.44.6. Please try again."; continue }
        if (-not (Confirm-N8nVersionsExist $run)) { continue }
        break
    }
    while ($true) {
        $target = ("$(Read-Host 'Do you want to test an upgrade to a newer n8n before you install it? Enter that version, for example 3.0.0, or press Enter to skip')").Trim()
        if (-not $target) { break }
        if (-not (Test-N8nVersionShape $target)) { Write-Warn 'That is not three numbers like 3.0.0. Please try again.'; continue }
        if (-not (Confirm-N8nVersionsExist @($target))) { continue }
        break
    }
    $wanted = @($run)
    if ($target -and -not ($wanted -contains $target)) { $wanted += $target }
    if ($wanted.Count -gt $script:MaxSlots) {
        Write-Warn "Preflight runs at most $($script:MaxSlots) sandboxes, and that is $($wanted.Count). Pick the $($script:MaxSlots) you need most."
        return (Read-SandboxVersions -Current $Current)
    }
    return [pscustomobject]@{ Wanted = $wanted; Target = $target }
}

function Confirm-N8nVersionsExist {
    param([string[]]$Versions)
    foreach ($v in $Versions) {
        $exists = Test-N8nVersionExists -Version $v
        if ($exists -eq $false) { Write-Warn "n8n has no release $v. Check Help > About in n8n and try again."; return $false }
        if ($null -eq $exists) { Write-Warn "Could not confirm $v with the registry; continuing. The download will say if it does not exist." }
    }
    return $true
}

function Show-SandboxPlan {
    # What will run, what it costs, and a warning (not a refusal) when the
    # worst case is more memory than Docker has.
    param([string[]]$Slots, [string]$Target)
    $count = @($Slots | Where-Object { $_ }).Count
    Write-Note "Preflight will run $count sandbox$(if ($count -ne 1) { 'es' }):"
    foreach ($line in (Format-SandboxSlots -Slots $Slots -Target $Target)) { Write-Note $line }
    Write-Note 'Each n8n version is about 2 GB to download the first time.'
    $need = Get-SandboxMemoryGB -Count $count
    $haveGB = Get-DockerMemoryGB
    if ($haveGB -and $need -gt $haveGB) {
        Write-Warn "Docker has $haveGB GB of memory and these could need about $need GB at the busiest. Replays may be slow or fail; Docker Desktop's Settings > Resources can give it more."
        if (-not (Confirm-Yes 'Continue anyway?')) { Stop-Install 'Nothing was changed.' }
    }
    elseif ($haveGB) { Write-Note "Docker has $haveGB GB of memory; these need about $need GB at the busiest." }
}

function Get-DockerMemoryGB {
    $docker = Find-Docker
    if (-not $docker) { return $null }
    $result = Invoke-Native -File $docker -Arguments @('info', '--format', '{{.MemTotal}}')
    $bytes = 0L
    if ($result.ExitCode -ne 0 -or -not [long]::TryParse((($result.Output -join '').Trim()), [ref]$bytes) -or $bytes -le 0) { return $null }
    return [Math]::Round($bytes / 1GB, 1)
}

function Wait-SandboxesHealthy {
    # The API's health does not wait for slots 2 to 4, so the installer does:
    # it does not say "ready" while a sandbox is still starting. Up to 5 minutes.
    param([string[]]$Slots, [int]$Seconds = 300)
    $services = @()
    for ($i = 0; $i -lt $script:MaxSlots; $i++) { if ($Slots[$i]) { $services += (Get-SandboxServiceName -Slot ($i + 1)) } }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        $result = Invoke-Compose -Arguments @('ps', '--format', '{{.Service}} {{.Health}}')
        $healthy = @()
        if ($result.ExitCode -eq 0) {
            foreach ($line in $result.Output) {
                $parts = ([string]$line).Trim() -split '\s+'
                if ($parts.Count -ge 2 -and $parts[1] -eq 'healthy') { $healthy += $parts[0] }
            }
        }
        $waiting = @($services | Where-Object { $healthy -notcontains $_ })
        if ($waiting.Count -eq 0) { return $true }
        if ((Get-Date) -gt $deadline) { Write-Warn "Still starting after $Seconds seconds: $($waiting -join ', '). Check  docker compose logs $($waiting[0])"; return $false }
        Start-Sleep -Seconds 3
    }
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
    Write-Host 'Safe to run again at any point. It never deletes your recordings, workflow history or settings, and never changes a secret in use.'
    if (Test-RunningFromArchive -Path $script:Root) {
        Stop-Install ("This is running from inside the ZIP, not from an extracted folder. Windows keeps those files in a temporary folder it deletes later, and your .env, which holds your secrets, would be deleted with it. " +
            "Close this window, right-click the ZIP, choose Extract All, and run install.cmd from the extracted folder.")
    }

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
                "Restore your old .env from a backup and run this again. To start over and DELETE that data, run  docker compose -p $($script:ProjectName) down -v  yourself; this installer never deletes your data.")
        }
        'PartlyFilledWithData' {
            Stop-Install ("Your .env is missing a secret and Preflight data already exists. A secret cannot be refilled safely against existing data. " +
                "Restore the .env you used before, or ask Logan for help.")
        }
    }

    $values = @{}
    # A version change is applied after every question is answered and the
    # backup is taken: the sandbox volume is reset first, then .env names the
    # new version. Declining anything on the way leaves both as they were.
    $oldSlots = Get-SandboxSlots -EnvValues $existing
    $newSlots = $oldSlots
    $resetSlots = @()
    $writeSlots = $false
    if ($state -eq 'Fresh' -or $state -eq 'PartlyFilled') {
        Write-Step 'A few questions'
        foreach ($key in 'PREFLIGHT_SECRET', 'POSTGRES_PASSWORD') {
            if (-not ($existing.ContainsKey($key) -and $existing[$key])) {
                $value = New-Secret
                Register-Secret $value
                $values[$key] = $value
            }
        }
        if (-not ($existing.ContainsKey('PREFLIGHT_N8N_VERSION') -and $existing['PREFLIGHT_N8N_VERSION'])) {
            $plan = Read-SandboxVersions -Current $oldSlots
            $newSlots = Resolve-SandboxSlots -Current $oldSlots -Wanted $plan.Wanted
            Show-SandboxPlan -Slots $newSlots -Target $plan.Target
            for ($i = 0; $i -lt $script:MaxSlots; $i++) { $values[$script:SlotKeys[$i]] = $newSlots[$i] }
            $values['COMPOSE_PROFILES'] = Get-ComposeProfiles -Slots $newSlots
            $writeSlots = $false
        }
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
        $newSlots = @($version, $oldSlots[1], $oldSlots[2], $oldSlots[3])
        # The version that made an existing slot 1 volume is unknown here, so
        # it cannot be assumed to match: treat it as a change.
        $resetSlots = @(@(1) | Where-Object { $volumes -contains (Get-SandboxVolumeName -Slot $_) })
        if (-not (Confirm-SandboxReset -Slots $resetSlots -Volumes $volumes -Old @('unknown', '', '', '') -New $newSlots)) { Stop-Install 'Nothing was changed.' }
        $writeSlots = $true
    }
    elseif ($state -eq 'Update') {
        Write-Step 'An existing install'
        Write-Ok 'Found your .env; keeping it as it is.'
        Register-Secret $existing['PREFLIGHT_SECRET']
        Register-Secret $existing['POSTGRES_PASSWORD']
        Write-Note 'Your sandboxes:'
        foreach ($line in (Format-SandboxSlots -Slots $oldSlots -Target '')) { Write-Note $line }
        if (Confirm-Yes 'Change them (add, remove or change a version)?') {
            $plan = Read-SandboxVersions -Current $oldSlots
            $newSlots = Resolve-SandboxSlots -Current $oldSlots -Wanted $plan.Wanted
            Show-SandboxPlan -Slots $newSlots -Target $plan.Target
            # Only slots that have a scratch database to lose.
            # Assigned first: the function returns its array as one object, so
            # piping it straight on would hand the filter the whole array.
            $changedSlots = Get-ChangedSlots -Old $oldSlots -New $newSlots
            $resetSlots = @($changedSlots | Where-Object { $volumes -contains (Get-SandboxVolumeName -Slot $_) })
            if (-not (Confirm-SandboxReset -Slots $resetSlots -Volumes $volumes -Old $oldSlots -New $newSlots)) { Stop-Install 'Nothing was changed.' }
            $writeSlots = $true
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

    if ($resetSlots.Count -gt 0) {
        Write-Step 'Resetting sandboxes whose n8n version changed'
        foreach ($slot in $resetSlots) { [void](Remove-SandboxVolume -Slot $slot) }
    }
    if ($writeSlots) {
        # Every slot written, so a slot left empty is blanked rather than left
        # holding a version the API would expect to be running.
        for ($i = 0; $i -lt $script:MaxSlots; $i++) { Update-EnvLine -Path $envPath -Key $script:SlotKeys[$i] -Value $newSlots[$i] }
        Update-EnvLine -Path $envPath -Key 'COMPOSE_PROFILES' -Value (Get-ComposeProfiles -Slots $newSlots)
        Write-Ok ('Sandboxes set: ' + (@($newSlots | Where-Object { $_ }) -join ', ') + '.')
    }

    Write-Step 'Downloading and starting Preflight (the first time takes a few minutes)'
    $pull = Invoke-Compose -Arguments @('pull') -Live
    if ($pull.ExitCode -ne 0) { Stop-Install "Downloading failed (exit code $($pull.ExitCode)). Check your internet connection and that Docker Desktop is running, then run this again." }
    $up = Invoke-Compose -Arguments @('up', '-d') -Live
    if ($up.ExitCode -ne 0) { Stop-Install "Starting failed (exit code $($up.ExitCode)). The messages above say why; a missing value in .env is the usual cause." }

    Write-Step 'Waiting for Preflight to be ready'
    if (-not (Wait-Ready)) { Stop-Install 'Preflight did not become ready.' }
    # What Compose will start, from what .env now says.
    $finalEnv = Read-EnvText ([System.IO.File]::ReadAllText($envPath))
    $running = Get-RunningSlots -Slots (Get-SandboxSlots -EnvValues $finalEnv) -Profiles ([string]$finalEnv['COMPOSE_PROFILES'])
    for ($i = 1; $i -lt $script:MaxSlots; $i++) {
        $set = [string]$finalEnv[$script:SlotKeys[$i]]
        if ($set -and -not $running[$i]) { Write-Warn "Sandbox slot $($i + 1) is set to n8n $set but is not turned on (its profile, sandbox-$($i + 1), is not in COMPOSE_PROFILES). Run this again and choose to change your sandboxes to fix it." }
    }
    if (-not (Wait-SandboxesHealthy -Slots $running)) { Stop-Install 'A sandbox did not become ready. The line above names it; run this again once it is fixed.' }
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
