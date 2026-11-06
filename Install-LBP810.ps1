#requires -version 5.1
<#
.SYNOPSIS
 One-file Canon LBP-810 Windows 11 x64 USB/CAPT diagnostic and test bootstrap.
.DESCRIPTION
 Detects printer, downloads checksum-verified native dev binary from this GitHub
 repository, tests CAPT, and attempts one physical test page.
 NO VM, WSL, driver swap, Windows print-queue installation or data upload.
.PARAMETER DiagnosticOnly
 Read-only Windows/PnP inspection; no native binary download or printing.
.PARAMETER SkipPrint
 Runs the native CAPT status check but does not send a paper page.
.PARAMETER SelfTest
 Checks script logic and the cached binary (if present), without USB or network.
#>
[CmdletBinding()]
param(
    [switch]$DiagnosticOnly,
    [switch]$SkipPrint,
    [switch]$SelfTest
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Root = Join-Path $env:LOCALAPPDATA 'CanonLBP810'
$BinDir = Join-Path $Root 'bin'
$LogDir = Join-Path $Root 'Logs'
New-Item -ItemType Directory -Path $BinDir, $LogDir -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $LogDir ("lbp810-{0}.log" -f $Stamp)
$JsonFile = Join-Path $LogDir ("lbp810-{0}.json" -f $Stamp)
$ExePath = Join-Path $BinDir 'lbp810-bridge.exe'
$ChecksumPath = Join-Path $BinDir 'lbp810-bridge.sha256'
$RepoBase = 'https://github.com/Alex66166/canon-lbp810-win11/releases/download/dev'
$Result = [ordered]@{
    timestamp = (Get-Date).ToString('o')
    status = 'NOT_STARTED'
    detected = $false
    osVersion = $null
    pnp = @()
    installedPrinterQueues = @()
    nativeAvailable = $false
    nativeSelfTest = $false
    captStatus = $false
    physicalPrintAttempted = $false
    physicalPrintReported = $false
    note = 'Direct USB test only; ordinary Ctrl+P queue is not implemented.'
    localLog = $LogFile
}
$Exit = 1

function Log([string]$Message, [string]$Level = 'INFO') {
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $entry
    Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8
}

function Assert-Windows11 {
    if (-not [Environment]::Is64BitOperatingSystem) { throw '64-bit Windows is required.' }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $Result.osVersion = [string]$os.Version
    Log ("OS: {0}; version {1}; build {2}" -f $os.Caption, $os.Version, $os.BuildNumber)
    if ([int]$os.BuildNumber -lt 22000) { throw 'Windows 11 (build 22000+) is required.' }
}

function Find-LBP810 {
    $devices = @()
    if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
        try {
            $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object {
                ($_.InstanceId -match 'VID_04A9&PID_260A') -or
                ($_.FriendlyName -match '(?i)\bLBP[\s\-]?810\b') -or
                ($_.InstanceId -match '(?i)USBPRINT\\Canon.*LBP[\-_]?810')
            })
        } catch {
            Log ("Get-PnpDevice unavailable: " + $_.Exception.Message) 'WARN'
        }
    }
    if ($devices.Count -eq 0) {
        $devices = @(Get-CimInstance Win32_PnPEntity | Where-Object {
            ($_.PNPDeviceID -match 'VID_04A9&PID_260A') -or
            ($_.Name -match '(?i)\bLBP[\s\-]?810\b') -or
            ($_.PNPDeviceID -match '(?i)USBPRINT\\Canon.*LBP[\-_]?810')
        } | ForEach-Object {
            [pscustomobject]@{
                FriendlyName = $_.Name
                InstanceId = $_.PNPDeviceID
                Status = $_.Status
            }
        })
    }
    $Result.pnp = @($devices | Select-Object FriendlyName, InstanceId, Status)
    foreach ($d in $Result.pnp) {
        Log ("PnP: {0} | {1} | {2}" -f $d.FriendlyName, $d.Status, $d.InstanceId)
    }
    try {
        $queues = @(Get-Printer -ErrorAction Stop | Where-Object {
            $_.Name -match '(?i)\bLBP[\s\-]?810\b'
        } | Select-Object Name, DriverName, PortName)
        $Result.installedPrinterQueues = $queues
        foreach ($q in $queues) {
            Log ("Existing Windows queue: {0}; driver={1}; port={2}" -f $q.Name, $q.DriverName, $q.PortName)
        }
    } catch {
        Log ("Unable to list Windows printers: " + $_.Exception.Message) 'WARN'
    }
    $Result.detected = ($Result.pnp.Count -gt 0)
    return $Result.detected
}

function Verify-Binary {
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $ChecksumPath -PathType Leaf)) { return $false }
    $expected = ((Get-Content -LiteralPath $ChecksumPath -Raw).Trim()).ToLowerInvariant()
    if ($expected -notmatch '^[a-f0-9]{64}$') { return $false }
    $actual = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($actual -eq $expected)
}

function Ensure-NativeBinary {
    if (Verify-Binary) {
        Log 'Cached native executable verified (SHA-256).'
        $Result.nativeAvailable = $true
        return
    }
    Log 'Downloading native bridge from GitHub dev prerelease.'
    $tempExe = Join-Path $BinDir 'lbp810-bridge.exe.part'
    $tempSha = Join-Path $BinDir 'lbp810-bridge.sha256.part'
    try {
        Invoke-WebRequest -Uri ($RepoBase + '/lbp810-bridge.exe') -OutFile $tempExe -UseBasicParsing
        Invoke-WebRequest -Uri ($RepoBase + '/lbp810-bridge.sha256') -OutFile $tempSha -UseBasicParsing
        $expected = ((Get-Content -LiteralPath $tempSha -Raw).Trim()).ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $tempExe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -notmatch '^[a-f0-9]{64}$' -or $actual -ne $expected) {
            throw 'SHA-256 mismatch; refusing to execute downloaded binary.'
        }
        Move-Item -LiteralPath $tempExe -Destination $ExePath -Force
        Move-Item -LiteralPath $tempSha -Destination $ChecksumPath -Force
    } catch {
        throw ("Verified native binary unavailable. GitHub Actions dev build may be missing: " + $_.Exception.Message)
    } finally {
        Remove-Item -LiteralPath $tempExe, $tempSha -Force -ErrorAction SilentlyContinue
    }
    if (-not (Verify-Binary)) { throw 'Downloaded executable failed integrity recheck.' }
    $Result.nativeAvailable = $true
    Log 'Native binary downloaded and SHA-256 verified.'
}

function Run-Bridge([string]$Command, [int]$TimeoutSeconds) {
    $suffix = $Command.TrimStart('-')
    $stdout = Join-Path $LogDir ("bridge-{0}-{1}.stdout.txt" -f $Stamp, $suffix)
    $stderr = Join-Path $LogDir ("bridge-{0}-{1}.stderr.txt" -f $Stamp, $suffix)
    Log ("Native {0}; timeout {1}s" -f $Command, $TimeoutSeconds)
    $proc = Start-Process -FilePath $ExePath -ArgumentList @($Command) -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    try {
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch {}
            throw ("Native test timed out during {0}." -f $Command)
        }
        $proc.Refresh()
        $code = [int]$proc.ExitCode
    } finally {
        $proc.Dispose()
    }
    foreach ($path in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $path) {
            foreach ($line in @(Get-Content -LiteralPath $path)) {
                if (-not [string]::IsNullOrWhiteSpace($line)) { Log $line 'NATIVE' }
            }
        }
    }
    if ($code -ne 0) {
        throw ("Bridge {0} returned {1}. Check logs: {2}" -f $Command, $code, $LogDir)
    }
}

try {
    Log 'Canon LBP-810 native Windows 11 test. No VM / USB driver changes.'
    if ($SelfTest) {
        Log 'Script self-test (without USB or network).'
        if ('USB\VID_04A9&PID_260A' -notmatch 'VID_04A9&PID_260A') { throw 'Detection regex failed.' }
        if (Test-Path -LiteralPath $ExePath) {
            if (-not (Verify-Binary)) { throw 'Existing native binary checksum invalid.' }
            Run-Bridge '--self-test' 30
            $Result.nativeSelfTest = $true
        } else {
            Log 'Native binary not cached; pure script self-test passed.'
        }
        $Result.status = 'SELFTEST_OK'
        $Exit = 0
    } else {
        Assert-Windows11
        if (-not (Find-LBP810)) {
            $Result.status = 'PRINTER_NOT_FOUND'
            $Result.note = 'Check USB power, cable and Device Manager.'
            Log 'No connected LBP-810 detected.' 'ERROR'
            $Exit = 2
        } elseif ($DiagnosticOnly) {
            Log 'Read-only diagnostic complete.'
            $Result.status = 'DIAGNOSTIC_OK'
            $Exit = 0
        } else {
            Ensure-NativeBinary
            Run-Bridge '--self-test' 60
            $Result.nativeSelfTest = $true
            Run-Bridge '--list' 20
            Run-Bridge '--status' 30
            $Result.captStatus = $true
            if ($SkipPrint) {
                Log 'CAPT status check complete; test print skipped.'
                $Result.status = 'CAPT_STATUS_OK'
                $Exit = 0
            } else {
                $Result.physicalPrintAttempted = $true
                Run-Bridge '--print-test' 150
                $Result.physicalPrintReported = $true
                $Result.status = 'CAPT_PRINT_COMMAND_COMPLETED'
                Log 'CAPT protocol reports job completion. Confirm actual paper output!'
                $Exit = 0
            }
        }
    }
} catch {
    $Result.status = 'FAILED'
    $Result.note = [string]$_.Exception.Message
    Log ("FAILED: " + $_.Exception.Message) 'ERROR'
    $Exit = 1
} finally {
    $Result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonFile -Encoding UTF8
    Log ("Log file: " + $LogFile)
    Log ("JSON result: " + $JsonFile)
    Log ("Outcome: " + $Result.status + " (exit " + $Exit + ")")
    Log 'Ctrl+P Windows printer queue is NOT installed by this prototype.'
}
exit $Exit
