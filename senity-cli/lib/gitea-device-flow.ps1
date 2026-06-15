# lib/gitea-device-flow.ps1
#
# OAuth2 Device Authorization Grant (RFC 8628) gegen Gitea (git.senity.ai).
# PowerShell-Mirror der bash-Lib gitea-device-flow.sh.
# Wird via dot-source (. ./lib/gitea-device-flow.ps1) in senity.ps1 geladen.
#
# Exit-Code-Konvention identisch zur Bash-Variante:
#   0 ok, 2 auth.json fehlt, 3 invalid_grant, 4 expired_token, 5 access_denied, 6 Netzwerk/Sonstiges
#
# Tokens werden NIE geloggt. Nur Status-Meldungen ueber Write-GiteaLog/Warn/Err.

# ---- Konstanten -------------------------------------------------------------
$script:GiteaHost          = if ($env:SENITY_GITEA_HOST)      { $env:SENITY_GITEA_HOST }      else { "https://git.senity.ai" }
$script:GiteaClientId      = if ($env:SENITY_GITEA_CLIENT_ID) { $env:SENITY_GITEA_CLIENT_ID } else { "" }
$script:GiteaScopes        = if ($env:SENITY_GITEA_SCOPES)    { $env:SENITY_GITEA_SCOPES }    else { "read:package read:repository" }
$script:GiteaPollHardCap   = if ($env:SENITY_GITEA_POLL_HARD_CAP)     { [int]$env:SENITY_GITEA_POLL_HARD_CAP }     else { 900 }
$script:GiteaPollCapInter  = if ($env:SENITY_GITEA_POLL_CAP_INTERVAL) { [int]$env:SENITY_GITEA_POLL_CAP_INTERVAL } else { 30 }

$script:SenityHomeDir = if ($env:SENITY_HOME) { $env:SENITY_HOME } else { Join-Path $env:USERPROFILE ".senity" }
$script:GiteaAuthFile = Join-Path $script:SenityHomeDir "auth.json"

$script:DockerConfigDir  = if ($env:DOCKER_CONFIG) { $env:DOCKER_CONFIG } else { Join-Path $env:USERPROFILE ".docker" }
$script:DockerConfigFile = Join-Path $script:DockerConfigDir "config.json"

# ---- Logging (Tokens NIE ausgeben) ------------------------------------------
function Write-GiteaLog  ([string]$Msg) { Write-Host "[gitea] $Msg" -ForegroundColor Magenta }
function Write-GiteaWarn ([string]$Msg) { Write-Host "[gitea] $Msg" -ForegroundColor Yellow }
function Write-GiteaErr  ([string]$Msg) { Write-Host "[gitea] $Msg" -ForegroundColor Red }

# ---- Dependency-Check -------------------------------------------------------
function Test-GiteaDeps {
    # PowerShell-Native: Invoke-RestMethod + ConvertTo/From-Json, keine externen Tools noetig.
    if (-not (Get-Command Invoke-RestMethod -ErrorAction SilentlyContinue)) {
        Write-GiteaErr "Invoke-RestMethod nicht verfuegbar — PowerShell 5+ noetig"
        return 6
    }
    return 0
}

# ---- Atomic Write (tmp + rename) --------------------------------------------
function Write-GiteaAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---- HTTP-Helper ------------------------------------------------------------
function Invoke-GiteaPost {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][hashtable]$Form
    )
    try {
        # PowerShell 7+ Invoke-RestMethod kann Form-Body direkt; 5.1 nicht — manuell encoden.
        $pairs = @()
        foreach ($k in $Form.Keys) {
            $pairs += "{0}={1}" -f [uri]::EscapeDataString($k), [uri]::EscapeDataString([string]$Form[$k])
        }
        $body = ($pairs -join "&")
        return Invoke-RestMethod -Method Post -Uri $Url -Body $body `
            -Headers @{ "Accept" = "application/json" } `
            -ContentType "application/x-www-form-urlencoded" `
            -ErrorAction Stop
    } catch {
        # Falls Gitea einen 4xx mit JSON-Body schickt, Response trotzdem extrahieren
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $raw = $reader.ReadToEnd()
            return ($raw | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            return $null
        }
    }
}

# ---- Endpoints --------------------------------------------------------------
function Invoke-GiteaDeviceInit {
    if (-not $script:GiteaClientId) {
        Write-GiteaErr "SENITY_GITEA_CLIENT_ID nicht gesetzt"
        return $null
    }
    $resp = Invoke-GiteaPost -Url "$($script:GiteaHost)/login/oauth/device" -Form @{
        client_id = $script:GiteaClientId
        scope     = $script:GiteaScopes
    }
    if (-not $resp) {
        Write-GiteaErr "Device-Init Netzwerkfehler"
        return $null
    }
    return $resp
}

function Invoke-GiteaPollToken {
    param(
        [Parameter(Mandatory)][string]$DeviceCode,
        [int]$Interval = 5
    )
    $start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    while ($true) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if (($now - $start) -ge $script:GiteaPollHardCap) {
            Write-GiteaErr "Polling-Hard-Cap ($($script:GiteaPollHardCap)s) erreicht"
            return @{ __exit = 4 }
        }
        Start-Sleep -Seconds $Interval
        $resp = Invoke-GiteaPost -Url "$($script:GiteaHost)/login/oauth/access_token" -Form @{
            grant_type    = "urn:ietf:params:oauth:grant-type:device_code"
            device_code   = $DeviceCode
            client_id     = $script:GiteaClientId
        }
        if (-not $resp) {
            Write-GiteaWarn "Polling-Netzwerkfehler, retry"
            continue
        }
        $errCode = $resp.error
        if (-not $errCode) {
            return $resp
        }
        switch ($errCode) {
            "authorization_pending" { continue }
            "slow_down" {
                $Interval += 5
                if ($Interval -gt $script:GiteaPollCapInter) { $Interval = $script:GiteaPollCapInter }
            }
            "expired_token" {
                Write-GiteaErr "device_code abgelaufen"
                return @{ __exit = 4 }
            }
            "access_denied" {
                Write-GiteaErr "Login abgelehnt"
                return @{ __exit = 5 }
            }
            default {
                Write-GiteaErr "Unbekannter OAuth-Fehler: $errCode"
                return @{ __exit = 6 }
            }
        }
    }
}

function Invoke-GiteaRefresh {
    param([Parameter(Mandatory)][string]$RefreshToken)
    if (-not $script:GiteaClientId) {
        Write-GiteaErr "SENITY_GITEA_CLIENT_ID nicht gesetzt"
        return @{ __exit = 6 }
    }
    $resp = Invoke-GiteaPost -Url "$($script:GiteaHost)/login/oauth/access_token" -Form @{
        grant_type    = "refresh_token"
        refresh_token = $RefreshToken
        client_id     = $script:GiteaClientId
    }
    if (-not $resp) {
        Write-GiteaErr "Refresh-Netzwerkfehler"
        return @{ __exit = 6 }
    }
    $errCode = $resp.error
    if (-not $errCode) {
        return $resp
    }
    if ($errCode -eq "invalid_grant") {
        return @{ __exit = 3 }
    }
    Write-GiteaErr "Refresh-Fehler: $errCode"
    return @{ __exit = 6 }
}

# ---- User-Code-Anzeige ------------------------------------------------------
function Show-GiteaUserCode {
    param(
        [Parameter(Mandatory)][string]$UserCode,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$UriComplete
    )
    Write-Host ""
    Write-Host "  Oeffne im Browser:  " -NoNewline
    Write-Host $Uri -ForegroundColor White
    Write-Host "  User-Code:          " -NoNewline
    Write-Host $UserCode -ForegroundColor Cyan
    Write-Host "  Direktlink:         " -NoNewline
    Write-Host $UriComplete -ForegroundColor White
    Write-Host ""
    if (Get-Command qrencode -ErrorAction SilentlyContinue) {
        try { & qrencode -t ANSIUTF8 -m 1 $UriComplete } catch {}
        Write-Host ""
    }
}

# ---- Auth-File IO -----------------------------------------------------------
function Read-GiteaAuth {
    if (-not (Test-Path $script:GiteaAuthFile)) {
        return $null
    }
    try {
        return (Get-Content -LiteralPath $script:GiteaAuthFile -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-GiteaAuth {
    param([Parameter(Mandatory)]$TokenResponse)
    $at = $TokenResponse.access_token
    $rt = $TokenResponse.refresh_token
    $expiresIn = if ($TokenResponse.expires_in) { [int]$TokenResponse.expires_in } else { 3600 }
    if (-not $at -or -not $rt) {
        Write-GiteaErr "Token-Response unvollstaendig"
        return $false
    }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $expiresAt = $now + [Math]::Max(60, $expiresIn - 60)

    # User-Info ziehen (best-effort)
    $userLogin = ""
    $userId = 0
    try {
        $userResp = Invoke-RestMethod -Method Get -Uri "$($script:GiteaHost)/api/v1/user" `
            -Headers @{ "Authorization" = "Bearer $at"; "Accept" = "application/json" } `
            -ErrorAction Stop
        if ($userResp.login) { $userLogin = $userResp.login }
        if ($userResp.id)    { $userId = [int]$userResp.id }
    } catch {}

    $payload = [ordered]@{
        gitea_user              = $userLogin
        gitea_user_id           = $userId
        refresh_token           = $rt
        access_token            = $at
        access_token_expires_at = $expiresAt
        scopes                  = $script:GiteaScopes
        connected_at            = $now
    }
    $json = $payload | ConvertTo-Json -Depth 4
    Write-GiteaAtomic -Path $script:GiteaAuthFile -Content $json

    # Windows-ACL: nur aktueller User darf lesen (Best-effort, kein Bruchgrund)
    try {
        $acl = Get-Acl $script:GiteaAuthFile
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $env:USERNAME, "FullControl", "Allow")
        $acl.SetAccessRule($rule)
        Set-Acl -Path $script:GiteaAuthFile -AclObject $acl
    } catch {}
    return $true
}

# ---- Docker-Config Patch ----------------------------------------------------
function Write-GiteaDockerConfig {
    param([Parameter(Mandatory)][string]$AccessToken)
    if (-not (Test-Path $script:DockerConfigDir)) {
        New-Item -ItemType Directory -Path $script:DockerConfigDir -Force | Out-Null
    }
    $existing = @{}
    if (Test-Path $script:DockerConfigFile) {
        try {
            $raw = Get-Content -LiteralPath $script:DockerConfigFile -Raw
            if ($raw.Trim()) {
                $obj = $raw | ConvertFrom-Json
                # ConvertFrom-Json liefert PSCustomObject — in Hashtable konvertieren
                $existing = @{}
                $obj.PSObject.Properties | ForEach-Object { $existing[$_.Name] = $_.Value }
            }
        } catch {}
    }
    if (-not $existing.ContainsKey("auths")) {
        $existing["auths"] = @{}
    } else {
        # auths von PSCustomObject in Hashtable konvertieren, damit wir patchen koennen
        if ($existing["auths"] -is [PSCustomObject]) {
            $authsHash = @{}
            $existing["auths"].PSObject.Properties | ForEach-Object { $authsHash[$_.Name] = $_.Value }
            $existing["auths"] = $authsHash
        }
    }
    $hostName = ($script:GiteaHost -replace '^https?://', '').TrimEnd('/')
    $authBytes = [System.Text.Encoding]::UTF8.GetBytes("oauth2:$AccessToken")
    $authB64 = [System.Convert]::ToBase64String($authBytes)
    $existing["auths"][$hostName] = @{ auth = $authB64 }

    $json = $existing | ConvertTo-Json -Depth 10
    Write-GiteaAtomic -Path $script:DockerConfigFile -Content $json
    return $true
}

function Remove-GiteaDockerEntry {
    if (-not (Test-Path $script:DockerConfigFile)) { return $true }
    try {
        $raw = Get-Content -LiteralPath $script:DockerConfigFile -Raw
        if (-not $raw.Trim()) { return $true }
        $obj = $raw | ConvertFrom-Json
        if (-not $obj.auths) { return $true }
        $hostName = ($script:GiteaHost -replace '^https?://', '').TrimEnd('/')
        $authsHash = @{}
        $obj.auths.PSObject.Properties | ForEach-Object {
            if ($_.Name -ne $hostName) { $authsHash[$_.Name] = $_.Value }
        }
        $cfg = @{}
        $obj.PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
        $cfg["auths"] = $authsHash
        $json = $cfg | ConvertTo-Json -Depth 10
        Write-GiteaAtomic -Path $script:DockerConfigFile -Content $json
        return $true
    } catch {
        return $false
    }
}

# ---- Revoke (best-effort) ---------------------------------------------------
function Invoke-GiteaRevoke {
    param([string]$RefreshToken)
    if (-not $RefreshToken) { return }
    try {
        Invoke-GiteaPost -Url "$($script:GiteaHost)/login/oauth/revoke" -Form @{
            token     = $RefreshToken
            client_id = $script:GiteaClientId
        } | Out-Null
    } catch {}
}

# ---- Token-Frische ----------------------------------------------------------
# Liefert "fresh" | "stale" | "missing"
function Get-GiteaTokenFreshness {
    param([int]$Skew = 60)
    if (-not (Test-Path $script:GiteaAuthFile)) { return "missing" }
    try {
        $a = Get-Content -LiteralPath $script:GiteaAuthFile -Raw | ConvertFrom-Json
        $exp = [int]$a.access_token_expires_at
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($exp -gt ($now + $Skew)) { return "fresh" } else { return "stale" }
    } catch {
        return "missing"
    }
}

# Symbole fuer den Dispatcher exportieren ist in dot-sourced Scripts implizit.
