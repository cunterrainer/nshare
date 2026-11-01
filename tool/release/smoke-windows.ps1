param([Parameter(Mandatory=$true)][string]$Installer)
$ErrorActionPreference = 'Stop'
$temporary = Join-Path $env:RUNNER_TEMP ('nshare-install-' + [Guid]::NewGuid())
$installed = Join-Path $temporary 'nshare installed'
$originalPath = [Environment]::GetEnvironmentVariable('Path', 'User')
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $setup = Start-Process -FilePath (Resolve-Path $Installer) -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$installed`"") -Wait -PassThru
    if ($setup.ExitCode -ne 0) { throw "Installer exited $($setup.ExitCode)" }
    $cli = Join-Path $installed 'nshare.exe'
    $help = & $cli --help
    if ($LASTEXITCODE -ne 0 -or ($help -join "`n") -notmatch 'Usage:') { throw 'Installed CLI help failed' }
    $addresses = & $cli --show-ip --include-loopback
    if ($LASTEXITCODE -ne 0 -or ($addresses -join "`n") -notmatch '127.0.0.1') { throw 'Installed CLI cannot enumerate network interfaces' }
    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($currentPath -split ';') -notcontains $installed) { throw 'Installer did not register the CLI PATH entry' }
    $gui = Start-Process -FilePath (Join-Path $installed 'gui\nshare_app.exe') -ArgumentList '--help' -Wait -PassThru
    if ($gui.ExitCode -ne 0) { throw 'Installed GUI or its native libraries failed to start' }
    $uninstall = Start-Process -FilePath (Join-Path $installed 'unins000.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
    if ($uninstall.ExitCode -ne 0) { throw "Uninstaller exited $($uninstall.ExitCode)" }
    if ([Environment]::GetEnvironmentVariable('Path', 'User') -ne $originalPath) { throw 'Uninstall did not preserve the pre-existing PATH' }
    if (Test-Path $cli) { throw 'Uninstall retained the application executable' }
    Write-Output 'PASS: per-user installation, CLI help/IP, native GUI startup, PATH registration and clean uninstall'
} finally {
    # The runner is disposable; restore its original PATH even after a failed assertion.
    [Environment]::SetEnvironmentVariable('Path', $originalPath, 'User')
    if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
