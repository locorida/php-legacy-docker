# Creates a locally trusted HTTPS certificate with mkcert.
#
#   .\scripts\setup-certs.ps1
#
# - Downloads a pinned mkcert release to tools\ and verifies its SHA-256 before running it.
#   mkcert installs a root CA, so the binary is never committed: a swapped .exe in a repository
#   would run on every contributor's machine and be invisible in code review. Only the checksum
#   is in the repo, where any change to it is visible.
# - "mkcert -install" creates a per-machine CA in the user's certificate store (no admin rights;
#   Windows asks for confirmation once). The CA key never leaves your user profile.
# - Writes certs\cert.pem + certs\key.pem for APP_DOMAIN, *.APP_DOMAIN, localhost and 127.0.0.1,
#   and renews them when they expire within 30 days.
# Afterwards: .\up.ps1 -Recreate (or: docker exec <APP_NAME> supervisorctl restart nginx)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = Read-EnvFile $root
$domain = Get-Cfg $cfg 'APP_DOMAIN' 'app.localhost'

$version = 'v1.4.4'
$url     = "https://github.com/FiloSottile/mkcert/releases/download/$version/mkcert-$version-windows-amd64.exe"
# Cross-checked against the Scoop "extras" manifest for mkcert 1.4.4.
$sha256  = 'd2660b50a9ed59eada480750561c96abc2ed4c9a38c6a24d93e30e0977631398'

$tools  = Join-Path $root 'tools'
$mkcert = Join-Path $tools 'mkcert.exe'
$certs  = Join-Path $root 'certs'
$certFile = Join-Path $certs 'cert.pem'
$keyFile  = Join-Path $certs 'key.pem'
New-Item -ItemType Directory -Force -Path $tools, $certs | Out-Null

if (-not (Test-Path $mkcert)) {
    Write-Host "Downloading mkcert $version ..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile "$mkcert.download" -UseBasicParsing
    Move-Item -Force "$mkcert.download" $mkcert
}

$actual = (Get-FileHash -Algorithm SHA256 $mkcert).Hash.ToLower()
if ($actual -ne $sha256) {
    Remove-Item $mkcert
    throw "SHA-256 mismatch for mkcert.exe (expected $sha256, got $actual). File deleted. If a proxy blocks the download, fetch $url manually into tools\mkcert.exe - the checksum is still enforced."
}
Write-Host "mkcert $version checksum OK."

& $mkcert -install
if ($LASTEXITCODE -ne 0) { throw 'mkcert -install failed.' }

$renew = $true
if (Test-Path $certFile) {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certFile
    $fromMkcert = $cert.Issuer -match 'mkcert'
    $coversDomain = $cert.Subject -match [regex]::Escape($domain) -or
        ($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | ForEach-Object { $_.Format($false) }) -match [regex]::Escape($domain)
    if ($fromMkcert -and $coversDomain -and $cert.NotAfter -gt (Get-Date).AddDays(30)) {
        Write-Host "Certificate for $domain is valid until $($cert.NotAfter.ToString('yyyy-MM-dd')), keeping it."
        $renew = $false
    }
}

if ($renew) {
    & $mkcert -cert-file $certFile -key-file $keyFile $domain "*.$domain" localhost 127.0.0.1
    if ($LASTEXITCODE -ne 0) { throw 'mkcert failed to create the certificate.' }
    Write-Host "Certificate written to certs\ for $domain, *.$domain, localhost, 127.0.0.1."
}

Write-Host 'Firefox: if it still warns, set security.enterprise_roots.enabled = true in about:config.'
