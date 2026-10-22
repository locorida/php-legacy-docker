# Builds the image (if needed) and starts the container.
#
#   .\up.ps1              start; builds the image on first run
#   .\up.ps1 -Rebuild     rebuild the image and replace the container
#   .\up.ps1 -Recreate    replace the container, e.g. after editing .env
#   .\up.ps1 -Watch       also start the file watcher (for OPCACHE_VALIDATE_TIMESTAMPS=0)
#
# Data (database, Redis) lives in named volumes and survives -Rebuild and -Recreate.
# If script execution is blocked: powershell -ExecutionPolicy Bypass -File .\up.ps1

param(
    [switch] $Rebuild,
    [switch] $Recreate,
    [switch] $Watch
)

# docker writes progress to stderr; with 'Stop' Windows PowerShell 5.1 would treat that as fatal.
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

. (Join-Path $root 'scripts\common.ps1')
$cfg = Read-EnvFile $root

$name  = Get-Cfg $cfg 'APP_NAME' 'php-legacy'
$image = "${name}:local"

function Invoke-Docker {
    & docker @args
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed (exit $LASTEXITCODE)." }
}

& docker info *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker is not reachable. Start Docker Desktop and try again.' }

# --- Image ------------------------------------------------------------------------------------
& docker image inspect $image *> $null
if ($Rebuild -or $LASTEXITCODE -ne 0) {
    $buildArgs = @('build', '--pull', '-t', $image)
    $phpImage = Get-Cfg $cfg 'PHP_IMAGE' ''
    if ($phpImage) { $buildArgs += @('--build-arg', "PHP_IMAGE=$phpImage") }
    Write-Host "Building $image (first build takes a few minutes) ..."
    Invoke-Docker @buildArgs $root
    $Recreate = $true
}

# --- Container --------------------------------------------------------------------------------
& docker container inspect $name *> $null
$exists = ($LASTEXITCODE -eq 0)

if ($exists -and $Recreate) {
    Write-Host 'Stopping old container (MariaDB shuts down cleanly) ...'
    & docker stop -t 120 $name | Out-Null
    Invoke-Docker rm $name | Out-Null
    $exists = $false
}

if ($exists) {
    Invoke-Docker start $name | Out-Null
} else {
    $projects = Resolve-HostPath $root (Get-Cfg $cfg 'PROJECTS_DIR' './app')
    $certs    = Resolve-HostPath $root './certs'
    New-Item -ItemType Directory -Force -Path $certs | Out-Null

    $runArgs = @(
        'run', '-d', '--name', $name,
        '--stop-timeout', '120',
        '--add-host', 'host.docker.internal:host-gateway',
        '-p', "127.0.0.1:$(Get-Cfg $cfg 'HTTP_PORT' '8080'):80",
        '-p', "127.0.0.1:$(Get-Cfg $cfg 'HTTPS_PORT' '8443'):443",
        '-p', "127.0.0.1:$(Get-Cfg $cfg 'DB_PORT' '3306'):3306",
        '-p', "127.0.0.1:$(Get-Cfg $cfg 'MAIL_SMTP_PORT' '1025'):1025",
        '-p', "127.0.0.1:$(Get-Cfg $cfg 'MAIL_UI_PORT' '8025'):8025",
        '-v', "${projects}:/var/www/html",
        '-v', "${certs}:/certs:ro",
        '-v', "${name}-db:/var/lib/mysql",
        '-v', "${name}-redis:/var/lib/redis"
    )

    $dataDir = Get-Cfg $cfg 'DATA_DIR' ''
    if ($dataDir) {
        $data = Resolve-HostPath $root $dataDir
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        $runArgs += @('-v', "${data}:/srv/data")
    }

    $initDb = Join-Path $root 'initdb'
    if (Test-Path $initDb) { $runArgs += @('-v', "$(Resolve-HostPath $root './initdb'):/docker-entrypoint-initdb.d:ro") }

    foreach ($key in 'TZ', 'DOCUMENT_ROOT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD', 'DB_BUFFER_POOL',
                     'DB_SQL_MODE', 'XDEBUG_MODE', 'OPCACHE_VALIDATE_TIMESTAMPS', 'WORKER_COMMAND') {
        if ($cfg.ContainsKey($key)) { $runArgs += @('-e', "$key=$($cfg[$key])") }
    }

    $runArgs += $image
    Invoke-Docker @runArgs | Out-Null
}

# --- Wait for the HEALTHCHECK -----------------------------------------------------------------
Write-Host -NoNewline 'Waiting for services '
$deadline = (Get-Date).AddSeconds(180)
do {
    Start-Sleep -Milliseconds 500
    $health = (& docker inspect --format '{{.State.Health.Status}}' $name 2>$null)
    Write-Host -NoNewline '.'
} while ($health -ne 'healthy' -and (Get-Date) -lt $deadline)
Write-Host ''
if ($health -ne 'healthy') {
    Write-Warning "Container is '$health'. Check: docker logs $name"
    exit 1
}

# --- Watcher ----------------------------------------------------------------------------------
if ($Watch) { Start-Watcher $root $name (Resolve-HostPath $root (Get-Cfg $cfg 'PROJECTS_DIR' './app')) }

$domain = Get-Cfg $cfg 'APP_DOMAIN' 'app.localhost'
Write-Host ''
Write-Host "  App      http://${domain}:$(Get-Cfg $cfg 'HTTP_PORT' '8080')"
Write-Host "           https://${domain}:$(Get-Cfg $cfg 'HTTPS_PORT' '8443')"
Write-Host "  Mailpit  http://localhost:$(Get-Cfg $cfg 'MAIL_UI_PORT' '8025')"
Write-Host "  MariaDB  127.0.0.1:$(Get-Cfg $cfg 'DB_PORT' '3306')  (user $(Get-Cfg $cfg 'DB_USER' 'app'))"
Write-Host "  Shell    docker exec -it $name bash"
