# Runs build-crate.ps1, the Windows build-crate.sh, on a GitHub Windows
# runner as a separate local user at Low integrity, and copies the tarball to
# $env:TEMPDIR.
#
# The runner user is an administrator, and the runner's credentials (a JWT
# that can write Actions caches and artifacts of this run) sit in
# C:\actions-runner, which every user can read and write by default. Here:
#
# - The build user is a new local user, not an administrator.
# - Its processes run at Low integrity, so they cannot write to anything
#   labelled Medium, which is everything not labelled otherwise: the tool and
#   PATH directories, the runner's work directory and the files later steps
#   read. They can write only to the work directory made for them.
# - C:\actions-runner and the runner's work directory lose the access that
#   every user inherits, so the build cannot read them either.
# - It gets the runner's environment without GITHUB_*, ACTIONS_*, RUNNER_*,
#   INPUT_* and the runner's Rust settings.
# - Every process it started is killed before the tarball is copied out.
#
# A process starts at the lower of its creator's integrity and its image's
# label, so a copy of cmd.exe labelled Low starts the build at Low, and its
# children inherit that.
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

# A new user for every build, so that nothing one build left reaches the next
# (selfbuild.yml builds twice in one job).
$user = 'qibuild' + -join (1..8 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
$password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)) + 'aA1!'
$secure = ConvertTo-SecureString $password -AsPlainText -Force
New-LocalUser -Name $user -Password $secure -PasswordNeverExpires -AccountNeverExpires | Out-Null

$root = "C:\$user"
$src = "$root\src"   # Medium, so the build cannot change it
$bin = "$root\bin"   # the Low cmd.exe
$work = "$root\work" # Low, the only place the build can write
New-Item -ItemType Directory $src, $bin, $work | Out-Null
Copy-Item "$PSScriptRoot\build-crate.ps1" $src
Copy-Item "$env:SystemRoot\System32\cmd.exe" "$bin\cmd.exe"
Invoke-Native icacls "$bin\cmd.exe" /setintegritylevel L /Q
Invoke-Native icacls $work /grant "${user}:(OI)(CI)M" /Q
Invoke-Native icacls $work /setintegritylevel '(OI)(CI)L' /Q

$out = "$work\out"
$log = "$work\build.log"
$pwsh = (Get-Process -Id $PID).Path
$cargoHome = "$work\cargo"

$psi = [Diagnostics.ProcessStartInfo]::new("$bin\cmd.exe")
# /s: strip only the outermost quotes, so the inner ones survive.
$psi.Arguments = "/d /s /c `"`"$pwsh`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$src\build-crate.ps1`" > `"$log`" 2>&1`""
$psi.UseShellExecute = $false
$psi.UserName = $user
$psi.Password = $secure
$psi.LoadUserProfile = $true
$psi.WorkingDirectory = $work
$psi.CreateNoWindow = $true
foreach ($name in @($psi.Environment.Keys)) {
    # Also the runner's Rust settings, such as the CARGO_TARGET_DIR that
    # selfbuild.yml sets, which point at places the build cannot write.
    if ($name -match '^(GITHUB_|ACTIONS_|RUNNER_|INPUT_|CARGO_|RUSTUP_|RUSTC|RUSTDOC|RUSTFLAGS$)') {
        $psi.Environment.Remove($name) | Out-Null
    }
}
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
    PATH                = "$cargoHome\bin;$env:PATH"
    OUT_DIR             = $out
    CRATE               = $env:CRATE
    VERSION             = $env:VERSION
    TARGET_ARCH         = $env:TARGET_ARCH
    FEATURES            = "$env:FEATURES"
    NO_DEFAULT_FEATURES = "$env:NO_DEFAULT_FEATURES"
}
foreach ($kv in $set.GetEnumerator()) { $psi.Environment[$kv.Key] = $kv.Value }

function Stop-BuildUser {
    Get-CimInstance Win32_Process | Where-Object {
        (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue).User -eq $user
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-ScheduledTask | Where-Object { $_.Principal.UserId -match $user } |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Disable-LocalUser -Name $user -ErrorAction SilentlyContinue
}

$code = 1
try {
    $process = [Diagnostics.Process]::Start($psi)
    # Show the log as it grows.
    $offset = 0
    while ($true) {
        $done = $process.WaitForExit(2000)
        if (Test-Path $log) {
            $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
            try {
                $stream.Seek($offset, 'Begin') | Out-Null
                $text = [IO.StreamReader]::new($stream).ReadToEnd()
                $offset = $stream.Position
            } finally { $stream.Dispose() }
            if ($text) { [Console]::Out.Write($text) }
        }
        if ($done) { break }
    }
    $code = $process.ExitCode
} finally {
    Stop-BuildUser
}
if ($code) { throw "the build exited with $code" }

# Only a regular file, so that a link cannot make the upload pick up
# anything else.
$item = Get-Item -LiteralPath "$out\$tarball" -Force -ErrorAction SilentlyContinue
if (-not $item -or $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "$tarball is missing or not a regular file"
}
Copy-Item -LiteralPath $item.FullName "$env:TEMPDIR\$tarball"
"$env:TEMPDIR\$tarball"
