#requires -version 5.1
<#
.SYNOPSIS
  Install tested third-party Canon LBP-810 bridge on Windows 11 x64.
.DESCRIPTION
  One-command bootstrap for jellybebra/canon-lbp810 v1.0.0. This repository
  DOES NOT claim authorship of the bridge or independent hardware verification.
  The upstream author reports a successful physical Windows test page.
  It checks the pinned GitHub release SHA-256 before running the installer.
.PARAMETER DiagnosticOnly
  Only show OS, USB and existing printer state. No downloads or changes.
.PARAMETER SkipPrint
  Install the bridge without submitting the Windows test page.
.PARAMETER SelfTest
  Offline script and pinned-release metadata checks (for CI, no hardware).
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

$SourceRepo = 'jellybebra/canon-lbp810'
$Version = 'v1.0.0'
$ArchiveName = 'Canon-LBP810-Windows11-x64-1.0.0.zip'
# GitHub release assets API reported this SHA-256 digest for v1.0.0.
# Pinned here to prevent silently installing changed upstream binaries.
$ExpectedSha256 = 'f2256e82eecceb928a9e1cedf12636eb5ae031263be799cf89361b4003795a51'
$ArchiveUrl = "https://github.com/$SourceRepo/releases/download/$Version/$ArchiveName"
# GitHub API is an alternative official download entry point, not a third-party mirror.
$ArchiveApiUrl = 'https://api.github.com/repos/jellybebra/canon-lbp810/releases/assets/487273787'
$Root = Join-Path $env:LOCALAPPDATA 'CanonLBP810'
$Work = Join-Path $Root 'community-v1.0.0'
$Logs = Join-Path $Root 'Logs'
$Archive = Join-Path $Work $ArchiveName
$Extract = Join-Path $Work 'extracted'
$Package = Join-Path $Extract 'Canon-LBP810-Windows11-x64-1.0.0'
$ElevatedInstaller = Join-Path $Package 'scripts\Install.ps1'
$TestPage = Join-Path $Package 'scripts\Print-TestPage.ps1'
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

New-Item -ItemType Directory -Path $Work, $Logs -Force | Out-Null
$Log = Join-Path $Logs ('community-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

function Log([string]$Message) {
    $text = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message
    Write-Host $text
    Add-Content -LiteralPath $Log -Value $text -Encoding UTF8
}
function Require-OS {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'This package is only for x64 Windows.'
    }
    $os = Get-CimInstance -Class Win32_OperatingSystem
    Log ("Windows build: {0}; 64-bit OS confirmed" -f $os.BuildNumber)
    if ([int]$os.BuildNumber -lt 22000) { throw 'Windows 11 is required.' }
}
function Find-Canon {
    $devices = @(Get-CimInstance Win32_PnPEntity | Where-Object {
        $_.PNPDeviceID -match 'VID_04A9&PID_260A' -or
        $_.PNPDeviceID -match '(?i)USBPRINT\\Canon.*LBP[\-_]?810' -or
        $_.Name -match '(?i)\bLBP[\s\-]?810\b'
    })
    foreach ($device in $devices) {
        Log ("Device: {0}; {1}; status={2}" -f $device.Name, $device.PNPDeviceID, $device.Status)
    }
    if ($devices.Count -lt 1) { throw 'Canon LBP-810 not found. Connect and power on USB printer first.' }
    $exactUsbMatches = @($devices | Where-Object {
        $_.PNPDeviceID -match 'VID_04A9&PID_260A'
    })
    if ($exactUsbMatches.Count -eq 0) {
        throw 'LBP-810 name was found but USB VID:PID 04A9:260A is not verified.'
    }
    return $devices
}
function Check-Collisions {
    $queue = Get-Printer -Name 'Canon LBP-810' -ErrorAction SilentlyContinue
    if ($queue -and (($queue.DriverName -ne 'Microsoft PS Class Driver') -or
                    ($queue.PortName -ne 'CanonLBP810_CAPT'))) {
        throw 'Existing printer named Canon LBP-810 uses another driver/port. Refusing to overwrite it.'
    }

    $port = Get-PrinterPort -Name 'CanonLBP810_CAPT' -ErrorAction SilentlyContinue
    if ($port -and (($port.PrinterHostAddress -ne '127.0.0.1') -or
                   ([int]$port.PortNumber -ne 9100))) {
        throw 'Existing CanonLBP810_CAPT port has different settings. Refusing to overwrite it.'
    }

    $service = Get-CimInstance Win32_Service -Filter "Name='CanonLBP810Bridge'" -ErrorAction SilentlyContinue
    if ($service) {
        $expected = Join-Path $env:ProgramFiles 'Canon LBP-810 Bridge\bin\lbp810-bridge.exe'
        if ($service.PathName -notlike ('*' + $expected + '*')) {
            throw 'Service CanonLBP810Bridge belongs to an unexpected executable; refusing to overwrite it.'
        }
    }
}
function Verify-Archive {
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { return $false }
    $actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actual -ceq $ExpectedSha256
}
function Get-Archive {
    if (Verify-Archive) {
        Log 'Pinned release ZIP is already cached and SHA-256 verified.'
        return
    }

    Log "Downloading original GitHub release: $SourceRepo $Version"
    Log "Expected SHA-256: $ExpectedSha256"
    $part = "$Archive.part"

    # A GitHub Release asset can fail through some VPNs/proxies with HTTP 504.
    # Try distinct OFFICIAL GitHub delivery paths. Always verify the pinned hash.
    # Never trust the remote checksum file or install a partially downloaded ZIP.
    $sources = @(
        [pscustomobject]@{ name = 'GitHub release (curl)'; url = $ArchiveUrl; mode = 'curl' },
        [pscustomobject]@{ name = 'GitHub API release asset (curl)'; url = $ArchiveApiUrl; mode = 'api-curl' },
        [pscustomobject]@{ name = 'GitHub release (PowerShell)'; url = $ArchiveUrl; mode = 'iwr' },
        [pscustomobject]@{ name = 'GitHub API release asset (PowerShell)'; url = $ArchiveApiUrl; mode = 'api-iwr' }
    )

    $attemptLog = @()
    foreach ($source in $sources) {
        $maxTries = 2
        for ($attempt = 1; $attempt -le $maxTries; $attempt++) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            Log ("Attempt {0}/{1}: {2}" -f $attempt, $maxTries, $source.name)
            try {
                if ($source.mode -like '*curl') {
                    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
                    if (-not (Test-Path -LiteralPath $curl)) {
                        throw 'Built-in Windows curl.exe unavailable.'
                    }
                    $args = @(
                        '--fail', '--location', '--silent', '--show-error',
                        '--connect-timeout', '15',
                        '--max-time', '110',
                        '--retry', '1',
                        '--retry-all-errors',
                        '--retry-delay', '3',
                        '--output', $part
                    )
                    if ($source.mode -eq 'api-curl') {
                        $args += @('--header', 'Accept: application/octet-stream',
                                   '--header', 'X-GitHub-Api-Version: 2022-11-28',
                                   '--header', 'User-Agent: Canon-LBP810-Bootstrap')
                    }
                    $args += $source.url
                    & $curl @args
                    if ($LASTEXITCODE -ne 0) {
                        throw ("curl.exe returned {0}" -f $LASTEXITCODE)
                    }
                } else {
                    $params = @{
                        Uri = $source.url
                        OutFile = $part
                        TimeoutSec = 110
                        UseBasicParsing = $true
                    }
                    if ($source.mode -eq 'api-iwr') {
                        $params.Headers = @{
                            'Accept' = 'application/octet-stream'
                            'X-GitHub-Api-Version' = '2022-11-28'
                            'User-Agent' = 'Canon-LBP810-Bootstrap'
                        }
                    }
                    Invoke-WebRequest @params
                }

                if (-not (Test-Path -LiteralPath $part -PathType Leaf)) {
                    throw 'Download did not produce a file.'
                }
                $size = (Get-Item -LiteralPath $part).Length
                Log ("Downloaded {0} bytes; checking SHA-256..." -f $size)
                $actual = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actual -cne $ExpectedSha256) {
                    throw ("Downloaded data do not match pinned SHA-256 ({0})." -f $actual)
                }
                Move-Item -LiteralPath $part -Destination $Archive -Force
                if (-not (Verify-Archive)) { throw 'Cached release verification failed.' }
                Log ("Official GitHub release verified via {0}." -f $source.name)
                return
            } catch {
                $msg = [string]$_.Exception.Message
                Log ("Download failed on {0}: {1}" -f $source.name, $msg)
                $attemptLog += ("{0}: {1}" -f $source.name, $msg)
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                if ($attempt -lt $maxTries) { Start-Sleep -Seconds (3 * $attempt) }
            }
        }
    }
    throw ("No official GitHub download route succeeded. Printer detection is OK, " +
        "but the ZIP is not installed. Check VPN/proxy access to GitHub Releases. " +
        "Last error: " + $attemptLog[-1])
}
function Extract-Package {
    if (Test-Path -LiteralPath $Extract) {
        Remove-Item -LiteralPath $Extract -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Extract -Force | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $Extract -Force
    foreach ($required in @(
        $ElevatedInstaller,
        $TestPage,
        (Join-Path $Package 'bin\lbp810-bridge.exe'),
        (Join-Path $Package 'ghostscript\bin\gswin64c.exe'),
        (Join-Path $Package 'LICENSE.txt')
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Release ZIP is incomplete: $required"
        }
    }
}
function Run-Installer {
    Log 'Installing signed Microsoft PS queue and upstream local CAPT bridge.'
    Log 'Windows will request administrator approval (UAC).'
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "' + $ElevatedInstaller + '"'
    $p = Start-Process -FilePath $PsExe -Verb RunAs -ArgumentList $arg -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "Upstream installer returned exit code $($p.ExitCode)." }
    $printer = Get-Printer -Name 'Canon LBP-810' -ErrorAction Stop
    $svc = Get-Service -Name 'CanonLBP810Bridge' -ErrorAction Stop
    if ($printer.DriverName -ne 'Microsoft PS Class Driver' -or
        $printer.PortName -ne 'CanonLBP810_CAPT' -or
        $svc.Status -ne 'Running') {
        throw 'Installation returned without a correctly configured Canon LBP-810 queue and running bridge service.'
    }
    Log 'Installed Canon LBP-810 queue with Microsoft PS Class Driver; service running.'
}
function Print-TestPage {
    $bridgeLog = Join-Path $env:ProgramData 'Canon LBP-810 Bridge\spool\bridge.log'
    $beforeBytes = 0L
    if (Test-Path -LiteralPath $bridgeLog -PathType Leaf) {
        $beforeBytes = (Get-Item -LiteralPath $bridgeLog).Length
    }
    Log 'Submitting ONE standard Windows test page.'
    & $PsExe -NoProfile -ExecutionPolicy Bypass -File $TestPage
    if ($LASTEXITCODE -ne 0) { throw 'Windows test-page submission failed.' }
    Log 'PrintUI successfully submitted the job. Waiting for CAPT bridge completion log...'
    $deadline = (Get-Date).AddSeconds(100)
    $confirmed = $false
    do {
        Start-Sleep -Seconds 2
        if (-not (Test-Path -LiteralPath $bridgeLog -PathType Leaf)) { continue }
        try {
            $file = [IO.File]::Open($bridgeLog, [IO.FileMode]::Open,
                [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                if ($file.Length -lt $beforeBytes) { $beforeBytes = 0L }
                [void]$file.Seek($beforeBytes, [IO.SeekOrigin]::Begin)
                $reader = New-Object IO.StreamReader($file)
                $newText = $reader.ReadToEnd()
                if ($newText -match '(?im)\bCompleted job\s+\d+\b') {
                    $confirmed = $true
                    break
                }
                if ($newText -match '(?im)\b(error|failed|exception)\b') {
                    Log 'Bridge log contains a possible error. Review it if printing fails.'
                }
            } finally {
                $file.Dispose()
            }
        } catch {
            Log ('Bridge log read postponed: ' + $_.Exception.Message)
        }
    } while ((Get-Date) -lt $deadline)
    if ($confirmed) {
        Log 'The upstream CAPT bridge reported a completed print job.'
        Log 'Check the paper physically: the software cannot verify page quality.'
    } else {
        throw "Windows accepted the job, but bridge completion was not observed within 100 seconds. Inspect $bridgeLog"
    }
    Log ('Bridge log: ' + $bridgeLog)
}

try {
    Log 'Canon LBP-810 Windows 11 x64 verified-community bridge bootstrap'
    Log "Source: https://github.com/$SourceRepo (AGPL-3.0-or-later)"
    if ($SelfTest) {
        if ($ExpectedSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid pinned checksum.' }
        if (-not $ArchiveUrl.StartsWith('https://github.com/')) { throw 'Insecure release URL.' }
        Log 'Self-test OK: pinned metadata and URL validated, no printer/installer accessed.'
        exit 0
    }
    Require-OS
    [void](Find-Canon)
    Check-Collisions
    if ($DiagnosticOnly) {
        Log 'Diagnostics complete. No downloads, installations or print jobs.'
        exit 0
    }
    Get-Archive
    Extract-Package
    Run-Installer
    if (-not $SkipPrint) { Print-TestPage }
    Log 'Installer finished. Open Word -> Ctrl+P -> Canon LBP-810.'
    Log 'NOTE: successful job submission is not proof of physical output.'
    exit 0
} catch {
    Log ('ERROR: ' + $_.Exception.Message)
    Log ('Log: ' + $Log)
    exit 1
}
