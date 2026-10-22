# Helpers shared by up.ps1, down.ps1 and setup-certs.ps1. Dot-source, don't run.

# Reads KEY=VALUE lines from .env (created from .env.example on first use).
function Read-EnvFile([string] $root) {
    $envFile = Join-Path $root '.env'
    if (-not (Test-Path $envFile)) {
        Copy-Item (Join-Path $root '.env.example') $envFile
        Write-Host 'Created .env from .env.example.'
    }
    $cfg = @{}
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$') {
            $value = $Matches[2]
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
            $cfg[$Matches[1]] = $value
        }
    }
    return $cfg
}

function Get-Cfg([hashtable] $cfg, [string] $key, [string] $default) {
    if ($cfg.ContainsKey($key) -and $cfg[$key] -ne '') { return $cfg[$key] }
    return $default
}

# Absolute path with forward slashes, as docker -v expects it on Windows.
function Resolve-HostPath([string] $root, [string] $path) {
    if (-not [System.IO.Path]::IsPathRooted($path)) { $path = Join-Path $root $path }
    return ([System.IO.Path]::GetFullPath($path)) -replace '\\', '/'
}

function Start-Watcher([string] $root, [string] $container, [string] $path) {
    $pidFile = Join-Path $root '.watch-reload.pid'
    if (Test-Path $pidFile) {
        $old = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) {
            Write-Host 'Watcher is already running.'
            return
        }
    }
    $p = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'scripts\watch-reload.ps1'),
        '-Container', $container, '-Path', $path)
    Set-Content -Path $pidFile -Value $p.Id
    Write-Host "Watcher started (PID $($p.Id)), log: $(Join-Path $root 'watch-reload.log')"
}

function Stop-Watcher([string] $root) {
    $pidFile = Join-Path $root '.watch-reload.pid'
    if (-not (Test-Path $pidFile)) { return }
    $old = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($old) { Stop-Process -Id $old -ErrorAction SilentlyContinue }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    Write-Host 'Watcher stopped.'
}
