#!/usr/bin/env pwsh
# Rendert user-guide.html via Chrome / Edge headless nach user-guide.pdf.
# Beide Browser unterstuetzen --headless --print-to-pdf, kein pandoc / LaTeX noetig.

[CmdletBinding()]
param(
    [string]$InputHtml  = (Join-Path $PSScriptRoot "user-guide.html"),
    [string]$OutputPdf  = (Join-Path $PSScriptRoot "user-guide.pdf"),
    [string]$BrowserOverride = ""
)

$ErrorActionPreference = "Stop"

function Find-Browser {
    if ($BrowserOverride) {
        if (Test-Path $BrowserOverride) { return $BrowserOverride }
        throw "BrowserOverride existiert nicht: $BrowserOverride"
    }

    $candidates = @(
        "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "${env:LocalAppData}\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    throw "Kein Chrome / Edge gefunden. Mit -BrowserOverride explizit angeben."
}

if (-not (Test-Path $InputHtml)) {
    throw "HTML-Quelle fehlt: $InputHtml"
}

$browser = Find-Browser
Write-Host "[render-pdf] Browser: $browser" -ForegroundColor Magenta
Write-Host "[render-pdf] Input:   $InputHtml" -ForegroundColor Magenta
Write-Host "[render-pdf] Output:  $OutputPdf" -ForegroundColor Magenta

$absInput  = (Resolve-Path $InputHtml).Path
$inputUri  = "file:///" + ($absInput -replace '\\', '/')

$tmpProfile = Join-Path $env:TEMP "senity-pdf-render-$PID"
New-Item -ItemType Directory -Path $tmpProfile -Force | Out-Null

try {
    & $browser `
        --headless=new `
        --disable-gpu `
        --no-sandbox `
        --no-pdf-header-footer `
        --user-data-dir="$tmpProfile" `
        --print-to-pdf="$OutputPdf" `
        $inputUri 2>$null | Out-Null

    if (-not (Test-Path $OutputPdf)) {
        throw "PDF wurde nicht erzeugt. Browser-Output pruefen."
    }
    $size = (Get-Item $OutputPdf).Length
    Write-Host "[render-pdf] PDF erzeugt: $OutputPdf ($([math]::Round($size/1KB,1)) KB)" -ForegroundColor Green
}
finally {
    Remove-Item -Recurse -Force $tmpProfile -ErrorAction SilentlyContinue
}
