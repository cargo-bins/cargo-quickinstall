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

# Some crates are published without a lockfile, so fall back to no `--locked`
# just in case of spurious failure.
& $cargo @installArgs --locked
if ($LASTEXITCODE) { Invoke-Native $cargo @installArgs }

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
Invoke-Native "$env:SystemRoot\System32\tar.exe" --format v7 --options gzip:compression-level=9 -czf $tarball -C $binDir @binaries
$tarball
