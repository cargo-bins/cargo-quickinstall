# A CMake toolchain file for Linux targets that the build machine can run,
# see build-crate.sh.
#
# It uses the same zig compilers as cargo-zigbuild's own toolchain file, but
# leaves out CMAKE_SYSTEM_NAME, so that CMake doesn't build in cross-compiling
# mode. cmake-rs runs CMake from a build script, so TARGET is the Rust target,
# and cargo-zigbuild has set CC_<target> and CXX_<target> to its wrappers.
string(REPLACE "-" "_" _target "$ENV{TARGET}")
set(CMAKE_C_COMPILER "$ENV{CC_${_target}}")
set(CMAKE_CXX_COMPILER "$ENV{CXX_${_target}}")
set(CMAKE_C_LINKER_DEPFILE_SUPPORTED FALSE)
set(CMAKE_CXX_LINKER_DEPFILE_SUPPORTED FALSE)

# For MySQL's client library (mysqlclient-src). It looks for libresolv with
# find_library(), which doesn't search zig's libc, but zig links -lresolv
# fine. And it decides whether libc is musl by looking for
# /etc/alpine-release on the build machine.
set(RESOLV_LIBRARY resolv CACHE FILEPATH "")
if("$ENV{TARGET}" MATCHES "-musl")
  set(LINUX_ALPINE 1)
endif()
