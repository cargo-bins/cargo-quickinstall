# The Windows counterpart of build-crate.sh, which windows-sandbox/build.ps1
# runs as the build user at Low integrity. build-crate.sh cannot run there:
# the MSYS runtime behind Git's bash fails at Low integrity, because it
# creates named objects where only Medium can.
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

New-Item -ItemType Directory -Force $env:TEMP, $env:OUT_DIR | Out-Null

$cargo = Join-Path $env:CARGO_HOME 'bin\cargo.exe'
$rustup = Join-Path $env:CARGO_HOME 'bin\rustup.exe'

# Downloads the crate and every package that `cargo install` can need for it,
# with or without --locked and with any features, into CARGO_HOME, like
# fetch_crate in build-crate.sh. Every cargo here runs in an empty directory
# and names the manifest, as cargo reads .cargo\config.toml from the current
# directory up: one in the crate could set a rustc wrapper and run code here.
function Invoke-FetchCrate {
    $work = Join-Path $env:TEMP "cargo-fetch-$([guid]::NewGuid())"
    $root = Join-Path $work 'root'
    $empty = Join-Path $work 'empty'
    New-Item -ItemType Directory (Join-Path $root 'src'), $empty | Out-Null
    New-Item -ItemType File (Join-Path $root 'src\lib.rs') | Out-Null
    # The crate itself, and its index entry, through a package that depends
    # on it. That works for crates without a library too: cargo warns, but
    # resolves and downloads them anyway.
    @"
[package]
name = "quickinstall-fetch"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
$env:CRATE = "=$env:VERSION"
"@ | Set-Content -LiteralPath (Join-Path $root 'Cargo.toml')
    Push-Location $empty
    try {
        Invoke-Native $cargo fetch --manifest-path (Join-Path $root 'Cargo.toml')

        # What `cargo install --locked` builds with: the lockfile in the crate.
        $crateFile = Get-ChildItem -Recurse -File (Join-Path $env:CARGO_HOME 'registry\cache') -Filter "$env:CRATE-$env:VERSION.crate" |
            Select-Object -First 1
        $extracted = Join-Path $work 'crate'
        New-Item -ItemType Directory $extracted | Out-Null
        $stream = [IO.File]::OpenRead($crateFile.FullName)
        try {
            $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
            [Formats.Tar.TarFile]::ExtractToDirectory($gzip, $extracted, $false)
        } finally { $stream.Dispose() }
        $src = Join-Path $extracted "$env:CRATE-$env:VERSION"
        $manifest = Join-Path $src 'Cargo.toml'
        $lock = Join-Path $src 'Cargo.lock'
        if (Test-Path -LiteralPath $lock) {
            & $cargo fetch --locked --manifest-path $manifest
            Remove-Item -LiteralPath $lock
        }

        # And what it builds with without --locked: a fresh resolution, which,
        # with the crate as the root, covers all its features. If that fails,
        # the build still has what the package above resolved.
        & $cargo generate-lockfile --manifest-path $manifest
        if (-not $LASTEXITCODE) { & $cargo fetch --locked --manifest-path $manifest }
    } finally { Pop-Location }
    Remove-Item -Recurse -Force -LiteralPath $work
    $global:LASTEXITCODE = 0
}

if ($phase -ne 'build') {
    $rustupInit = Join-Path $env:TEMP 'rustup-init.exe'
    Invoke-WebRequest "https://static.rust-lang.org/rustup/dist/$env:RUSTUP_HOST/rustup-init.exe" -OutFile $rustupInit
    Invoke-Native $rustupInit -y --quiet --profile minimal --no-modify-path --default-toolchain stable
    Remove-Item $rustupInit

    if (-not (& $rustup target list --installed | Where-Object { $_ -eq $env:TARGET_ARCH })) {
        Invoke-Native $rustup target add $env:TARGET_ARCH
    }
    Invoke-FetchCrate
}
if ($phase -eq 'fetch') { exit 0 }

# From here on nothing needs the network, and the sandbox runs it without.
$env:CARGO_NET_OFFLINE = 'true'

$cargoRoot = Join-Path $env:TEMP "cargo-root-$([guid]::NewGuid())"
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
    if (-not (Test-Path -LiteralPath $crates2)) { return @() }
    # cargo leaves an empty file behind when it installed nothing.
    $json = Get-Content -Raw $crates2 | ConvertFrom-Json -AsHashtable
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
    $manifest = Get-ChildItem -Directory (Join-Path $env:CARGO_HOME 'registry\src') -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "$env:CRATE-$env:VERSION\Cargo.toml" } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
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

# Package up the binaries so that they can be untarred in ~/.cargo/bin, with
# the tar.exe that comes with Windows.
$tarball = Join-Path $env:OUT_DIR "$env:CRATE-$env:VERSION-$env:TARGET_ARCH.tar.gz"
$tar = "$env:SystemRoot\System32\tar.exe"
Invoke-Native $tar --format v7 --options gzip:compression-level=9 -czf $tarball -C $binDir @binaries
Invoke-Native $tar -tvzf $tarball
$tarball
