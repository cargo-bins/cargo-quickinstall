import os


TARGET_ARCH_TO_BUILD_OS = {
    "x86_64-apple-darwin": "macos-latest",
    "aarch64-apple-darwin": "macos-latest",
    "x86_64-unknown-linux-gnu": "ubuntu-20.04",
    "x86_64-unknown-linux-musl": "ubuntu-20.04",
    "x86_64-pc-windows-msvc": "windows-latest",
    "aarch64-pc-windows-msvc": "windows-latest",
    "aarch64-unknown-linux-gnu": "ubuntu-20.04",
    "aarch64-unknown-linux-musl": "ubuntu-20.04",
    "armv7-unknown-linux-musleabihf": "ubuntu-20.04",
    "armv7-unknown-linux-gnueabihf": "ubuntu-20.04",
}


def get_build_os(target_arch: str) -> str:
    try:
        return TARGET_ARCH_TO_BUILD_OS[target_arch]
    except KeyError:
        raise ValueError(f"Unrecognised target arch: {target_arch}")


def get_target_architectures() -> list[str]:
    target_arch = os.environ.get("TARGET_ARCH", None)
    if target_arch in TARGET_ARCH_TO_BUILD_OS:
        return [target_arch]

    if target_arch == "all":
        return list(TARGET_ARCH_TO_BUILD_OS.keys())

    try:
        rustc_version_output = subprocess.run(
            ["rustc", "--version", "--verbose"], capture_output=True, text=True
        )
        current_arch = [
            line.split("host: ")[1]
            for line in rustc_version_output.stdout.splitlines()
            if line.startswith("host: ")
        ][0]
        return [current_arch]
    except:
        raise ValueError(f"rustc did not tell us its host: {rustc_version_output}")
