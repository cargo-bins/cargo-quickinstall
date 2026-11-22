# Runs build-crate.ps1 for one PHASE in the AppContainer, waits for it and
# exits with its exit code. windows-sandbox/build.ps1 starts this as the build
# user, so that the AppContainer is that user's: an AppContainer process
# keeps its creator's user and groups, and the runner user is an
# administrator.
#
# The fetch phase gets the internetClient capability, the build phase, which
# runs the crate's build scripts and proc macros, gets none, so no network.
param(
    [Parameter(Mandatory)] [ValidateSet('fetch', 'build')] [string] $Phase,
    [Parameter(Mandatory)] [string] $Container,
    [Parameter(Mandatory)] [string] $Log
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -Path "$PSScriptRoot\AppContainer.cs"
# The profile gives the AppContainer its own folders and registry. Its SID
# depends on the name only, so build.ps1 knows it already.
$null = [QuickinstallAppContainer]::Create($Container)

$environment = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($kv in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
    $environment[$kv.Key] = $kv.Value
}
$environment['PHASE'] = $Phase
$capabilities = if ($Phase -eq 'fetch') { [string[]]@('S-1-15-3-1') } else { [string[]]@() }

$pwsh = (Get-Process -Id $PID).Path
# /s: strip only the outermost quotes, so the inner ones survive.
$command = "`"$env:SystemRoot\System32\cmd.exe`" /d /s /c `"`"$pwsh`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\build-crate.ps1`" >> `"$Log`" 2>&1`""
$process = [QuickinstallAppContainer]::Start($Container, $capabilities, $command, $env:HOME, $environment)
try {
    while (-not $process.WaitForExit(1000)) {}
    $code = $process.ExitCode
} finally {
    # Kills everything the build left running.
    $process.Dispose()
}
exit $code
