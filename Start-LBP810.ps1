#requires -version 5.1
<#
.SYNOPSIS
  One-command Canon LBP-810 bootstrap directly from GitHub.
.DESCRIPTION
  Downloads the latest Install-LBP810.ps1 from this repository and starts it
  in a separate Windows PowerShell process. The main script detects and tests
  the USB device; this launcher itself changes no device configuration.

  In PowerShell, run:
    irm https://raw.githubusercontent.com/Alex66166/canon-lbp810-win11/main/Start-LBP810.ps1 | iex

  This executes code from a public GitHub repository. Review the source first
  if you do not trust the repository or its current maintainers.
#>
[CmdletBinding()]
param(
    [switch]$DiagnosticOnly,
    [switch]$SkipPrint,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

$source = 'https://raw.githubusercontent.com/Alex66166/canon-lbp810-win11/main/Install-LBP810.ps1'
$root = Join-Path $env:LOCALAPPDATA 'CanonLBP810'
$localScript = Join-Path $root 'Install-LBP810.ps1'
$winPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

try {
    if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
        throw 'Windows 11 x64 is required.'
    }
    if (-not (Test-Path -LiteralPath $winPS -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 was not found.'
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null

    Write-Host 'Canon LBP-810: downloading latest installer from GitHub...'
    Invoke-WebRequest -Uri $source -OutFile $localScript -UseBasicParsing

    # Refuse to execute a truncated or syntactically invalid download.
    if ((Get-Item -LiteralPath $localScript).Length -lt 1000) {
        throw 'Downloaded PowerShell file is unexpectedly short.'
    }
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $localScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw 'Downloaded PowerShell file contains syntax errors.'
    }

    $cli = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $localScript)
    if ($DiagnosticOnly) { $cli += '-DiagnosticOnly' }
    if ($SkipPrint)      { $cli += '-SkipPrint' }
    if ($SelfTest)       { $cli += '-SelfTest' }

    Write-Host 'Canon LBP-810: running hardware checks...'
    & $winPS @cli
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        throw ("Canon LBP-810 script returned exit code {0}. See %LOCALAPPDATA%\CanonLBP810\Logs." -f $code)
    }
    Write-Host 'Canon LBP-810: script finished. Check console and local diagnostics.'
} catch {
    Write-Error ("Canon LBP-810 launcher failed: " + $_.Exception.Message)
}
