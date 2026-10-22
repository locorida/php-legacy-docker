# Watches the code on the Windows side and gracefully reloads PHP-FPM (and restarts the optional
# worker) whenever a PHP file changes. Needed only with OPCACHE_VALIDATE_TIMESTAMPS=0.
# Normally started by up.ps1 -Watch and stopped by down.ps1.

param(
    [Parameter(Mandatory)] [string] $Container,
    [Parameter(Mandatory)] [string] $Path,
    [int] $DebounceMs = 400
)

$ErrorActionPreference = 'Stop'
$logFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'watch-reload.log'
$extensions = @('.php', '.inc', '.phtml')
$ignore = '[\\/](\.git|\.idea|node_modules|vendor)[\\/]'

function Write-Log([string] $text) {
    Add-Content -Path $logFile -Value ('{0:HH:mm:ss} {1}' -f (Get-Date), $text) -Encoding UTF8
}

function Invoke-Reload([string] $reason) {
    # docker writes to stderr; with 'Stop' that would end the watcher on Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $out = & docker exec $Container supervisorctl signal USR2 php-fpm 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log "php-fpm reloaded ($reason)" }
    else { Write-Log "php-fpm reload failed: $($out -join ' ')" }

    # The worker only exists when WORKER_COMMAND is set; status exits 0 only if it is running.
    & docker exec $Container supervisorctl status worker *> $null
    if ($LASTEXITCODE -eq 0) {
        & docker exec $Container supervisorctl restart worker *> $null
        Write-Log 'worker restarted'
    }
}

$watcher = New-Object System.IO.FileSystemWatcher $Path
$watcher.IncludeSubdirectories = $true
$watcher.InternalBufferSize = 65536
$watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, DirectoryName'
$watcher.EnableRaisingEvents = $true
$subscriptions = foreach ($eventName in 'Changed', 'Created', 'Deleted', 'Renamed', 'Error') {
    Register-ObjectEvent -InputObject $watcher -EventName $eventName
}

Write-Log "watching $Path (PID $PID)"
$pending = $null
$lastEvent = Get-Date
try {
    while ($true) {
        $e = Wait-Event -Timeout 1
        if ($e) {
            Remove-Event -EventIdentifier $e.EventIdentifier
            if ($e.SourceEventArgs -is [System.IO.ErrorEventArgs]) {
                # Buffer overflow, e.g. during a branch switch: reload to be safe.
                $pending = 'many changes'
            } else {
                $file = $e.SourceEventArgs.FullPath
                if ($file -notmatch $ignore -and $extensions -contains [System.IO.Path]::GetExtension($file).ToLower()) {
                    $pending = $file
                }
            }
            $lastEvent = Get-Date
            continue
        }
        if ($pending -and ((Get-Date) - $lastEvent).TotalMilliseconds -ge $DebounceMs) {
            Invoke-Reload $pending
            $pending = $null
        }
    }
} finally {
    $subscriptions | ForEach-Object { Unregister-Event -SourceIdentifier $_.Name -ErrorAction SilentlyContinue }
    $watcher.Dispose()
    Write-Log 'watcher stopped'
}
