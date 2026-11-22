# The Windows counterpart of build-crate.sh, which windows-sandbox/build.ps1
# runs in an AppContainer of the build user. build-crate.sh cannot run there:
# the MSYS runtime behind Git's bash fails at Low integrity, which that is,
# because it creates named objects where only Medium can.
#
# Installs a toolchain into CARGO_HOME and RUSTUP_HOME, builds
# $CRATE@$VERSION for $TARGET_ARCH and packages its binaries into
# $OUT_DIR\$CRATE-$VERSION-$TARGET_ARCH.tar.gz. Keep it in step with
# build-crate.sh, PHASE included: fetch installs the toolchain and downloads
# the crate and everything it can depend on, and runs no crate code; build
# builds offline from that and packages; without PHASE it does both.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$phase = if ($env:PHASE) { $env:PHASE } else { 'all' }
if ($phase -notin 'fetch', 'build', 'all') { throw "Unknown PHASE $phase" }

foreach ($name in 'CRATE', 'VERSION', 'TARGET_ARCH', 'OUT_DIR', 'CARGO_HOME', 'RUSTUP_HOME', 'RUSTUP_HOST') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { throw "$name is not set" }
}

function Invoke-Native {
    $exe, $rest = $args
    & $exe @rest
    if ($LASTEXITCODE) { throw "$exe exited with $LASTEXITCODE" }
}

# .NET rather than cmdlets for files here: in the AppContainer, some cmdlets
# (Remove-Item) fail on the access check of C:\, which it cannot read.
$null = [IO.Directory]::CreateDirectory($env:TEMP), [IO.Directory]::CreateDirectory($env:OUT_DIR)

$cargo = Join-Path $env:CARGO_HOME 'bin\cargo.exe'
$rustup = Join-Path $env:CARGO_HOME 'bin\rustup.exe'

# Downloads the crate and every package that `cargo install` can need for it,
# with or without --locked and with any features, into CARGO_HOME, like
# fetch_crate in build-crate.sh. cargo runs in the current directory, which
# build.ps1 makes the work directory, and is given the manifests, as it reads
# .cargo\config.toml from the current directory up: one in the crate could set
# a rustc wrapper and run code here. (Push-Location would not work: it needs
# to read the directories above, which the AppContainer cannot.)
function Invoke-FetchCrate {
    $work = Join-Path $env:TEMP "cargo-fetch-$([guid]::NewGuid())"
    $root = Join-Path $work 'root'
    $null = [IO.Directory]::CreateDirectory((Join-Path $root 'src'))
    [IO.File]::WriteAllText((Join-Path $root 'src\lib.rs'), '')
    # The crate itself, and its index entry, through a package that depends
    # on it. That works for crates without a library too: cargo warns, but
    # resolves and downloads them anyway.
    [IO.File]::WriteAllText((Join-Path $root 'Cargo.toml'), @"
[package]
name = "quickinstall-fetch"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
$env:CRATE = "=$env:VERSION"
"@)
    Invoke-Native $cargo fetch --manifest-path (Join-Path $root 'Cargo.toml')

    # What `cargo install --locked` builds with: the lockfile in the crate.
    $crateFile = [IO.Directory]::EnumerateFiles((Join-Path $env:CARGO_HOME 'registry\cache'), "$env:CRATE-$env:VERSION.crate", 'AllDirectories') |
        Select-Object -First 1
    $extracted = Join-Path $work 'crate'
    $null = [IO.Directory]::CreateDirectory($extracted)
    $stream = [IO.File]::OpenRead($crateFile)
    try {
        $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
        [Formats.Tar.TarFile]::ExtractToDirectory($gzip, $extracted, $false)
    } finally { $stream.Dispose() }
    $src = Join-Path $extracted "$env:CRATE-$env:VERSION"
    $manifest = Join-Path $src 'Cargo.toml'
    $lock = Join-Path $src 'Cargo.lock'
    if ([IO.File]::Exists($lock)) {
        & $cargo fetch --locked --manifest-path $manifest
        [IO.File]::Delete($lock)
    }

    # And what it builds with without --locked: a fresh resolution, which,
    # with the crate as the root, covers all its features. If that fails,
    # the build still has what the package above resolved.
    & $cargo generate-lockfile --manifest-path $manifest
    if (-not $LASTEXITCODE) { & $cargo fetch --locked --manifest-path $manifest }
    [IO.Directory]::Delete($work, $true)
    $global:LASTEXITCODE = 0
}

if ($phase -ne 'build') {
    $rustupInit = Join-Path $env:TEMP 'rustup-init.exe'
    Invoke-WebRequest "https://static.rust-lang.org/rustup/dist/$env:RUSTUP_HOST/rustup-init.exe" -OutFile $rustupInit
    Invoke-Native $rustupInit -y --quiet --profile minimal --no-modify-path --default-toolchain stable
    [IO.File]::Delete($rustupInit)

    if (-not (& $rustup target list --installed | Where-Object { $_ -eq $env:TARGET_ARCH })) {
        Invoke-Native $rustup target add $env:TARGET_ARCH
    }
    Invoke-FetchCrate
}
if ($phase -eq 'fetch') { exit 0 }

# From here on nothing needs the network, and the sandbox runs it without.
$env:CARGO_NET_OFFLINE = 'true'

$cargoRoot = Join-Path $env:TEMP "cargo-root-$([guid]::NewGuid())"
# In an AppContainer GetTempPath ignores TEMP and TMP and returns the
# container's own folder, work\AppData\Local\Packages\<name>\AC\Temp, which is
# where `cargo install` would build. That is long enough to take OpenSSL's
# object paths past MAX_PATH, so build in a short directory instead.
$env:CARGO_TARGET_DIR = Join-Path $env:HOME 't'
$env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS = '1'
$env:CARGO_PROFILE_RELEASE_LTO = 'fat'
$env:OPENSSL_STATIC = '1'
$env:CARGO_REGISTRIES_CRATES_IO_PROTOCOL = 'sparse'

function Invoke-CargoInstall($features) {
    $installArgs = @('install', $env:CRATE, '--version', $env:VERSION, '--target', $env:TARGET_ARCH, '--root', $cargoRoot)
    if ($env:NO_DEFAULT_FEATURES -eq 'true') { $installArgs += '--no-default-features' }
    if ($features) { $installArgs += '--features', $features }

    # Some crates are published without a lockfile, so fall back to no `--locked`
    # just in case of spurious failure.
    & $cargo @installArgs --locked
    if ($LASTEXITCODE) { Invoke-Native $cargo @installArgs }
}

# Returns the names of the binaries that were installed. A function's output
# is unrolled, so wrap each call in @() to always get an array back.
function Get-Binaries {
    $crates2 = Join-Path $cargoRoot '.crates2.json'
    if (-not [IO.File]::Exists($crates2)) { return @() }
    # cargo leaves an empty file behind when it installed nothing.
    $json = [IO.File]::ReadAllText($crates2) | ConvertFrom-Json -AsHashtable
    if (-not $json -or -not $json.ContainsKey('installs')) { return @() }
    @(
        $json.installs.GetEnumerator() |
            Where-Object { $_.Key.StartsWith("$env:CRATE ") } |
            ForEach-Object { $_.Value.bins }
    )
}

# The features that the crate's binary named after the crate needs, read from
# the manifest that `cargo install` unpacked.
function Get-BinRequiredFeatures {
    $registrySrc = Join-Path $env:CARGO_HOME 'registry\src'
    $manifest = if ([IO.Directory]::Exists($registrySrc)) {
        [IO.Directory]::GetDirectories($registrySrc) |
            ForEach-Object { Join-Path $_ "$env:CRATE-$env:VERSION\Cargo.toml" } |
            Where-Object { [IO.File]::Exists($_) } |
            Select-Object -First 1
    }
    if (-not $manifest) {
        "Could not find the manifest of $env:CRATE $env:VERSION" | Out-Host
        return @()
    }
    $metadata = & $cargo metadata --manifest-path $manifest --no-deps --offline --format-version 1 | ConvertFrom-Json
    if ($LASTEXITCODE) { throw "cargo metadata exited with $LASTEXITCODE" }
    @(
        $metadata.packages[0].targets |
            Where-Object { $_.kind -contains 'bin' -and $_.name -eq $env:CRATE } |
            ForEach-Object { if ($_.PSObject.Properties['required-features']) { $_.'required-features' } }
    )
}

$features = "$env:FEATURES"
Invoke-CargoInstall $features

# Collect binaries
$binaries = @(Get-Binaries)

# Some crates put their binary behind a feature that is not on by default,
# and then `cargo install` succeeds without installing anything. Turn on what
# the binary named after the crate needs and build again. Other binaries are
# left off: those are usually examples or development tools.
if (-not $binaries) {
    $required = @(Get-BinRequiredFeatures) -join ','
    if ($required) {
        "Building again with the features that bin `"$env:CRATE`" needs: $required"
        $features = (@($features, $required) | Where-Object { $_ }) -join ','
        Invoke-CargoInstall $features
        $binaries = @(Get-Binaries)
    }
}
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

# Package up the binaries so that they can be untarred in ~/.cargo/bin, as a
# V7 tarball like build-crate.sh makes. With .NET: the tar.exe that comes with
# Windows fails in the AppContainer, which may not ask for the free space of C:.
$tarball = Join-Path $env:OUT_DIR "$env:CRATE-$env:VERSION-$env:TARGET_ARCH.tar.gz"
$mode = [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute'
$file = [IO.File]::Create($tarball)
try {
    $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionLevel]::SmallestSize)
    $writer = [Formats.Tar.TarWriter]::new($gzip, [Formats.Tar.TarEntryFormat]::V7)
    try {
        foreach ($name in $binaries) {
            $path = Join-Path $binDir $name
            $entry = [Formats.Tar.V7TarEntry]::new([Formats.Tar.TarEntryType]::V7RegularFile, $name)
            $entry.Mode = $mode
            $entry.ModificationTime = [IO.File]::GetLastWriteTimeUtc($path)
            $entry.DataStream = [IO.File]::OpenRead($path)
            try { $writer.WriteEntry($entry) } finally { $entry.DataStream.Dispose() }
        }
    } finally { $writer.Dispose(); $gzip.Dispose() }
} finally { $file.Dispose() }
$tarball
