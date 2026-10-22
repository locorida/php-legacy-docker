# Stops the container (and the watcher). Data is kept.
#
#   .\down.ps1            stop
#   .\down.ps1 -Remove    stop and remove the container (volumes stay)
#   .\down.ps1 -Purge     remove container AND data volumes (asks first)

param(
    [switch] $Remove,
    [switch] $Purge
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot

. (Join-Path $root 'scripts\common.ps1')
$cfg  = Read-EnvFile $root
$name = Get-Cfg $cfg 'APP_NAME' 'php-legacy'

Stop-Watcher $root

# 120 s: give MariaDB time for a clean shutdown (supervisord allows it 90 s).
& docker stop -t 120 $name 2>$null | Out-Null
Write-Host "Stopped $name."

if ($Remove -or $Purge) {
    & docker rm $name 2>$null | Out-Null
    Write-Host "Removed container $name."
}

if ($Purge) {
    $answer = Read-Host "Delete volumes ${name}-db and ${name}-redis with all data? Type 'yes'"
    if ($answer -eq 'yes') {
        & docker volume rm "${name}-db" "${name}-redis" 2>$null | Out-Null
        Write-Host 'Volumes deleted.'
    } else {
        Write-Host 'Volumes kept.'
    }
}
