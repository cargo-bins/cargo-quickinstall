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

function Invoke-CargoInstall($features) {
    $installArgs = @('install', $env:CRATE, '--version', $env:VERSION, '--target', $env:TARGET_ARCH, '--root', $cargoRoot)
    if ($env:NO_DEFAULT_FEATURES -eq 'true') { $installArgs += '--no-default-features' }
    if ($features) { $installArgs += '--features', $features }

    # Some crates are published without a lockfile, so fall back to no `--locked`
    # just in case of spurious failure.
    & $cargo @installArgs --locked
    if ($LASTEXITCODE) { Invoke-Native $cargo @installArgs }
}

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
$binaries = Get-Binaries

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
        $binaries = Get-Binaries
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
