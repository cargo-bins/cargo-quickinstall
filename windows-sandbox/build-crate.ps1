# The Windows counterpart of build-crate.sh, which windows-sandbox/build.ps1
# runs as the build user at Low integrity. build-crate.sh cannot run there:
# the MSYS runtime behind Git's bash fails at Low integrity, because it
# creates named objects where only Medium can.
#
# Installs a toolchain into CARGO_HOME and RUSTUP_HOME, builds
# $CRATE@$VERSION for $TARGET_ARCH and packages its binaries into
# $OUT_DIR\$CRATE-$VERSION-$TARGET_ARCH.tar.gz. Keep it in step with
# build-crate.sh.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($name in 'CRATE', 'VERSION', 'TARGET_ARCH', 'OUT_DIR', 'CARGO_HOME', 'RUSTUP_HOME', 'RUSTUP_HOST') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set" }
}

function Invoke-Native {
    $exe, $rest = $args
    & $exe @rest
    if ($LASTEXITCODE) { throw "$exe exited with $LASTEXITCODE" }
}

New-Item -ItemType Directory -Force $env:TEMP, $env:OUT_DIR | Out-Null

$rustupInit = Join-Path $env:TEMP 'rustup-init.exe'
Invoke-WebRequest "https://static.rust-lang.org/rustup/dist/$env:RUSTUP_HOST/rustup-init.exe" -OutFile $rustupInit
Invoke-Native $rustupInit -y --quiet --profile minimal --no-modify-path --default-toolchain stable
Remove-Item $rustupInit
$cargo = Join-Path $env:CARGO_HOME 'bin\cargo.exe'
$rustup = Join-Path $env:CARGO_HOME 'bin\rustup.exe'

if (-not (& $rustup target list --installed | Where-Object { $_ -eq $env:TARGET_ARCH })) {
    Invoke-Native $rustup target add $env:TARGET_ARCH
}

$cargoRoot = Join-Path $env:TEMP "cargo-root-$([guid]::NewGuid())"
$env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS = '1'
$env:CARGO_PROFILE_RELEASE_LTO = 'fat'
$env:OPENSSL_STATIC = '1'
$env:CARGO_REGISTRIES_CRATES_IO_PROTOCOL = 'sparse'

$installArgs = @('install', $env:CRATE, '--version', $env:VERSION, '--target', $env:TARGET_ARCH, '--root', $cargoRoot)
if ($env:NO_DEFAULT_FEATURES -eq 'true') { $installArgs += '--no-default-features' }
if ($env:FEATURES) { $installArgs += '--features', $env:FEATURES }

# The minor version of the stable Rust that was current when $CRATE@$VERSION
# was published, from its `pubtime` in the crates.io index. Releases come
# every six weeks: 1.80 was on 2024-07-25. Never below 1.70, the first cargo
# that uses the sparse index by default.
function Get-RustMinorAtPublish {
    $name = $env:CRATE.ToLowerInvariant()
    $path = switch ($name.Length) {
        1 { "1/$name" }
        2 { "2/$name" }
        3 { "3/$($name.Substring(0, 1))/$name" }
        default { "$($name.Substring(0, 2))/$($name.Substring(2, 2))/$name" }
    }
    $index = (Invoke-WebRequest "https://index.crates.io/$path").Content -split "`n" |
        Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
    $entry = $index | Where-Object { $_.vers -eq $env:VERSION } | Select-Object -First 1
    if (-not $entry) { return $null }
    $published = if ($entry.PSObject.Properties['pubtime'] -and $entry.pubtime) {
        [DateTimeOffset]::Parse($entry.pubtime)
    } else {
        [DateTimeOffset]::Parse('2015-05-15T00:00:00Z')
    }
    $days = ($published - [DateTimeOffset]::Parse('2024-07-25T00:00:00Z')).TotalDays
    [Math]::Max(70, 80 + [Math]::Floor($days / 42))
}

# Runs cargo, shows its output and keeps it in $buildLog.
$buildLog = Join-Path $env:TEMP 'cargo-install.log'
function Invoke-CargoLogged {
    & $cargo @args 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $buildLog | Out-Host
    $LASTEXITCODE
}

# Some crates are published without a lockfile, so fall back to no `--locked`
# just in case of spurious failure.
$status = Invoke-CargoLogged @installArgs --locked
if ($status) { $status = Invoke-CargoLogged @installArgs }
if ($status) {
    # Rust sometimes breaks old code on purpose, for example type inference
    # that the time crate before 0.3.35 relied on (1.80), or new methods
    # that take the place of a trait's (is_multiple_of in 1.87,
    # File::try_lock in 1.89). So when rustc rejected the code itself, try
    # once more with the Rust of the day it was published, and its lockfile.
    if (-not (Select-String -Quiet -Path $buildLog -Pattern '^error\[E[0-9]{4}\]|incompatible with current versions of Rust')) {
        throw "cargo exited with $status"
    }
    $currentMinor = [int]((& $cargo --version) -split '\.')[1]
    $oldMinor = Get-RustMinorAtPublish
    if (-not $oldMinor -or $oldMinor -ge $currentMinor) { throw "cargo exited with $status" }
    "Building again with Rust 1.$oldMinor, the stable Rust of the day $env:CRATE $env:VERSION was published (1.70 at the earliest)"
    $env:RUSTUP_TOOLCHAIN = "1.$oldMinor"
    Invoke-Native $rustup toolchain install $env:RUSTUP_TOOLCHAIN --profile minimal --no-self-update --target $env:TARGET_ARCH
    Invoke-Native $cargo @installArgs --locked
}

# Collect binaries
$installs = (Get-Content -Raw (Join-Path $cargoRoot '.crates2.json') | ConvertFrom-Json -AsHashtable).installs
$binaries = @(
    $installs.GetEnumerator() |
        Where-Object { $_.Key.StartsWith("$env:CRATE ") } |
        ForEach-Object { $_.Value.bins }
)
if (-not $binaries) { throw '`cargo-install` does not install any binaries!' }

$binDir = Join-Path $cargoRoot 'bin'
foreach ($file in $binaries) {
    $bytes = [byte[]]::new(2)
    $stream = [IO.File]::OpenRead((Join-Path $binDir $file))
    try { $null = $stream.Read($bytes, 0, 2) } finally { $stream.Dispose() }
    if ([Text.Encoding]::ASCII.GetString($bytes) -ne 'MZ') {
        throw "something wrong with $file. Should be recognised as executable."
    }
}

# Package up the binaries so that they can be untarred in ~/.cargo/bin, with
# the tar.exe that comes with Windows.
$tarball = Join-Path $env:OUT_DIR "$env:CRATE-$env:VERSION-$env:TARGET_ARCH.tar.gz"
$tar = "$env:SystemRoot\System32\tar.exe"
Invoke-Native $tar --format v7 --options gzip:compression-level=9 -czf $tarball -C $binDir @binaries
Invoke-Native $tar -tvzf $tarball
$tarball
