# Runs build-crate.ps1, the Windows build-crate.sh, on a GitHub Windows
# runner in an AppContainer of a separate local user, and copies the tarball
# to $env:TEMPDIR.
#
# The runner user is an administrator, and the runner's credentials (a JWT
# that can write Actions caches and artifacts of this run) sit in
# C:\actions-runner, which every user can read and write by default. Here:
#
# - The build user is a new local user, not an administrator.
# - The build runs in an AppContainer of that user (see AppContainer.cs and
#   run.ps1). That is Low integrity, so it cannot write to anything labelled
#   Medium, and on top of that it can open only what grants access to the
#   AppContainer or to all of them: the system and Program Files for reading,
#   the work directory made for it, and what is granted below.
# - It runs twice: build-crate.ps1's fetch phase, which installs Rust,
#   downloads the crate and its dependencies, and runs no crate code, and then
#   its build phase, which does, with no network: the AppContainer gets the
#   internetClient capability for the fetch phase only.
# - C:\actions-runner and the runner's work directory lose the access that
#   every user inherits, so the build user's other processes cannot read them
#   either.
# - It gets the runner's environment without GITHUB_*, ACTIONS_*, RUNNER_*,
#   INPUT_* and the runner's Rust settings.
# - Everything it started is killed when each phase ends, by the job object
#   the AppContainer runs in, and every process of the build user before the
#   tarball is copied out.
#
# Needs CRATE, VERSION, TARGET_ARCH and TEMPDIR, and FEATURES and
# NO_DEFAULT_FEATURES like build-crate.sh. The runner must have run nothing
# that can't be trusted before this script.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($name in 'CRATE', 'VERSION', 'TARGET_ARCH', 'TEMPDIR') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set" }
}
$tarball = "$env:CRATE-$env:VERSION-$env:TARGET_ARCH.tar.gz"

function Invoke-Native {
    $exe, $rest = $args
    & $exe @rest
    if ($LASTEXITCODE) { throw "$exe exited with $LASTEXITCODE" }
}

# Close the runner's directories to other users. The runner itself, SYSTEM
# and Administrators keep full access. The work directory is the parent of
# the repository directory that GITHUB_WORKSPACE names, for example D:\a.
$me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$runnerWork = Split-Path (Split-Path $env:GITHUB_WORKSPACE)
foreach ($dir in 'C:\actions-runner', $runnerWork) {
    if (Test-Path $dir) {
        Invoke-Native icacls $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "*${me}:(OI)(CI)F" /Q
    }
}

# AppContainers have no network isolation without the firewall service.
if ((Get-Service mpssvc).Status -ne 'Running') { throw 'The Windows Firewall service is not running' }

Add-Type -Path "$PSScriptRoot\AppContainer.cs"
$container = 'quickinstall-build'
$containerSid = [QuickinstallAppContainer]::Sid($container)

# Devices grant nothing to AppContainers. Without NUL, programs cannot start
# others with no stdin (cargo starting rustc). Without the mount manager,
# paths cannot be canonicalized (cargo unpacking a crate). These last until
# the runner reboots.
$null = [QuickinstallAppContainer]::DeviceDacl('\\.\NUL', "(A;;GRGW;;;$containerSid)")
$null = [QuickinstallAppContainer]::DeviceDacl('\\.\MountPointManager', "(A;;GR;;;$containerSid)")

# Tools outside Program Files that builds use, for reading and running:
# Strawberry Perl (openssl-src), the protoc and LLVM that build-version.sh
# installs with Chocolatey, and the Visual Studio instances, by which the cc
# crate finds MSVC. Once per runner: selfbuild.yml builds twice in one job.
$tools = @(
    'C:\Strawberry\perl'
    "$env:ProgramData\chocolatey\bin"
    "$env:ProgramData\Microsoft\VisualStudio"
    Get-ChildItem -Directory "$env:ProgramData\chocolatey\lib" -ErrorAction SilentlyContinue |
        Where-Object Name -Match '^(protoc|llvm)' | ForEach-Object FullName
)
foreach ($dir in $tools) {
    if ((Test-Path -LiteralPath $dir) -and -not ((icacls $dir) -match [regex]::Escape($containerSid))) {
        Invoke-Native icacls $dir /grant "*${containerSid}:(OI)(CI)RX" /T /C /Q
    }
}

# MSVC's cl.exe and link.exe start its telemetry tool, vctip.exe, which
# starts getmac.exe. Outside an AppContainer vctip.exe notes that it ran and
# stays quiet for a while; inside one it cannot, so it ran for every cl.exe and
# link.exe, which made a zellij build take twice as long. Builds do not need
# it, so move it out of the way, as Chromium does. These are TrustedInstaller's,
# so take them first. The runner is thrown away after the job.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path -LiteralPath $vswhere) {
    foreach ($vs in @(& $vswhere -all -products * -property installationPath)) {
        Get-ChildItem -Recurse -File -Filter vctip.exe (Join-Path $vs 'VC\Tools\MSVC') -ErrorAction SilentlyContinue |
            ForEach-Object {
                Invoke-Native takeown /F $_.FullName /A | Out-Null
                Invoke-Native icacls $_.FullName /grant '*S-1-5-32-544:F' /Q
                Rename-Item -LiteralPath $_.FullName "$($_.Name).disabled"
            }
    }
}

# A new user for every build, so that nothing one build left reaches the next
# (selfbuild.yml builds twice in one job).
$user = 'qibuild' + -join (1..8 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
$password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)) + 'aA1!'
$secure = ConvertTo-SecureString $password -AsPlainText -Force
New-LocalUser -Name $user -Password $secure -PasswordNeverExpires -AccountNeverExpires | Out-Null

$root = "C:\$user"
$src = "$root\src"   # the scripts, read-only for the build
$work = "$root\work" # Low, the only place the build can write
New-Item -ItemType Directory $src, $work | Out-Null
Copy-Item "$PSScriptRoot\build-crate.ps1", "$PSScriptRoot\run.ps1", "$PSScriptRoot\AppContainer.cs" $src
Invoke-Native icacls $src /grant "${user}:(OI)(CI)RX" "*${containerSid}:(OI)(CI)RX" /Q
Invoke-Native icacls $work /grant "${user}:(OI)(CI)M" "*${containerSid}:(OI)(CI)M" /Q
Invoke-Native icacls $work /setintegritylevel '(OI)(CI)L' /Q

$out = "$work\out"
$log = "$work\build.log"
$pwsh = (Get-Process -Id $PID).Path
$cargoHome = "$work\cargo"

$psi = [Diagnostics.ProcessStartInfo]::new($pwsh)
$psi.UseShellExecute = $false
$psi.UserName = $user
$psi.Password = $secure
$psi.LoadUserProfile = $true
$psi.WorkingDirectory = $work
$psi.CreateNoWindow = $true
foreach ($name in @($psi.Environment.Keys)) {
    # Also the runner's Rust settings, such as a CARGO_TARGET_DIR, which
    # can point at places the build cannot write.
    if ($name -match '^(GITHUB_|ACTIONS_|RUNNER_|INPUT_|CARGO_|RUSTUP_|RUSTC|RUSTDOC|RUSTFLAGS$)') {
        $psi.Environment.Remove($name) | Out-Null
    }
}
# MSYS programs (Git's bash, sh, perl and the rest of usr\bin) die at startup at
# Low integrity, as in the AppContainer, as they cannot create their shared
# objects. Drop their
# directories from PATH so that build scripts find the native tools instead,
# for example Strawberry Perl for openssl-src.
$path = ($env:PATH -split ';' | Where-Object {
        $_ -and -not (Test-Path -LiteralPath (Join-Path $_ 'msys-2.0.dll'))
    }) -join ';'
$hostArch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'aarch64' } else { 'x86_64' }
$set = [ordered]@{
    HOME                = $work
    USERPROFILE         = $work
    APPDATA             = "$work\AppData\Roaming"
    LOCALAPPDATA        = "$work\AppData\Local"
    TEMP                = "$work\tmp"
    TMP                 = "$work\tmp"
    CARGO_HOME          = $cargoHome
    RUSTUP_HOME         = "$work\rustup"
    RUSTUP_HOST         = "$hostArch-pc-windows-msvc"
    PATH                = "$cargoHome\bin;$path"
    OUT_DIR             = $out
    CRATE               = $env:CRATE
    VERSION             = $env:VERSION
    TARGET_ARCH         = $env:TARGET_ARCH
    FEATURES            = "$env:FEATURES"
    NO_DEFAULT_FEATURES = "$env:NO_DEFAULT_FEATURES"
}
foreach ($kv in $set.GetEnumerator()) { $psi.Environment[$kv.Key] = $kv.Value }

function Stop-BuildUser {
    # UserName is null rather than missing for processes we cannot query or
    # that exit meanwhile, so this is safe under StrictMode. GetOwner on
    # Win32_Process returns no User for those and failed the job.
    $left = @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
            Where-Object { $_.UserName -eq "$env:COMPUTERNAME\$user" })
    Write-Host "Stopping $($left.Count) leftover processes of $user"
    $left | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-ScheduledTask | Where-Object { $_.Principal.UserId -match $user } |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Disable-LocalUser -Name $user -ErrorAction SilentlyContinue
}

$offset = 0
# Shows what the build added to the log since the last call.
function Write-Log {
    if (Test-Path $log) {
        $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
        try {
            $stream.Seek($script:offset, 'Begin') | Out-Null
            $text = [IO.StreamReader]::new($stream).ReadToEnd()
            $script:offset = $stream.Position
        } finally { $stream.Dispose() }
        if ($text) { [Console]::Out.Write($text) }
    }
}

try {
    foreach ($phase in 'fetch', 'build') {
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$src\run.ps1`" -Phase $phase -Container $container -Log `"$log`""
        $process = [Diagnostics.Process]::Start($psi)
        while (-not $process.WaitForExit(2000)) { Write-Log }
        Write-Log
        if ($process.ExitCode) { throw "the $phase phase exited with $($process.ExitCode)" }
    }
} finally {
    Stop-BuildUser
}

# Only a regular file, so that a link cannot make the upload pick up
# anything else.
$item = Get-Item -LiteralPath "$out\$tarball" -Force -ErrorAction SilentlyContinue
if (-not $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "$tarball is missing or not a regular file"
}
Copy-Item -LiteralPath $item.FullName "$env:TEMPDIR\$tarball"
Invoke-Native "$env:SystemRoot\System32\tar.exe" -tvzf "$env:TEMPDIR\$tarball"
"$env:TEMPDIR\$tarball"
