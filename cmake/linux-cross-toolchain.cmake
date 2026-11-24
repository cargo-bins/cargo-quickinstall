# A CMake toolchain file for Linux targets that the build machine can't run,
# see build-crate.sh.
#
# It does what cargo-zigbuild's own toolchain file does. cmake-rs runs CMake
# from a build script, so TARGET is the Rust target, and cargo-zigbuild has
# set CC_<target> and friends to its wrappers. On top of that, it lets MySQL's
# client library (mysqlclient-src, diesel_cli's mysql-bundled feature) build,
# which in cross-compiling mode needs answers to its try_run() checks and host
# builds of the tools it runs during the build.
string(REPLACE "-" "_" _target "$ENV{TARGET}")
string(REGEX MATCH "^[^-]+" _arch "$ENV{TARGET}")
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR "${_arch}")
set(CMAKE_C_COMPILER "$ENV{CC_${_target}}")
set(CMAKE_CXX_COMPILER "$ENV{CXX_${_target}}")
set(CMAKE_AR "$ENV{AR_${_target}}")
set(CMAKE_RANLIB "$ENV{RANLIB_${_target}}")
set(CMAKE_C_LINKER_DEPFILE_SUPPORTED FALSE)
set(CMAKE_CXX_LINKER_DEPFILE_SUPPORTED FALSE)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# MySQL's try_run() checks, which can't run here. These hold for every Linux
# libc.
set(HAVE_SETNS_EXITCODE 0 CACHE STRING "")
set(HAVE_CLOCK_GETTIME_EXITCODE 0 CACHE STRING "")
set(HAVE_CLOCK_REALTIME_EXITCODE 0 CACHE STRING "")
# MySQL looks for libresolv with find_library(), which doesn't search zig's
# libc, but zig links -lresolv fine. And it decides whether libc is musl by
# looking for /etc/alpine-release on the build machine.
set(RESOLV_LIBRARY resolv CACHE FILEPATH "")
if("$ENV{TARGET}" MATCHES "-musl")
  set(LINUX_ALPINE 1)
endif()

# MySQL builds comp_err and uca9dump and runs them to generate sources. When
# cross-compiling, it leaves out comp_err and runs whatever comp_err is on
# PATH, and it would run the target's uca9dump. So once MySQL's top-level
# CMakeLists has run, build both for the host from the same sources, and make
# the build run those. CMake resolves target names in custom commands when it
# generates the build files, after this.
function(_quickinstall_mysql_host_tools)
  if(NOT TARGET uca9dump OR TARGET comp_err
     OR NOT EXISTS "${CMAKE_SOURCE_DIR}/utilities/comp_err.cc")
    return()
  endif()

  set(host "${CMAKE_BINARY_DIR}/quickinstall-host-tools")
  # comp_err uses OpenSSL through mysys, so the host build needs one too.
  # OpenSSL 3, which MySQL supports.
  set(host_ssl "/opt/openssl/3/${CMAKE_HOST_SYSTEM_PROCESSOR}-unknown-linux-gnu")
  if(NOT EXISTS "${host_ssl}")
    set(host_ssl system)
  endif()
  # cmake-rs points CC, CFLAGS and friends at the target, so drop them.
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E env --unset=CMAKE_TOOLCHAIN_FILE
      --unset=CC --unset=CXX --unset=CFLAGS --unset=CXXFLAGS --unset=LDFLAGS
      "${CMAKE_COMMAND}" -S "${CMAKE_SOURCE_DIR}" -B "${host}"
      -DCMAKE_C_COMPILER=cc -DCMAKE_CXX_COMPILER=c++
      -DCMAKE_BUILD_TYPE=Release -DWITHOUT_SERVER=ON
      -DWITH_EDITLINE=bundled "-DWITH_SSL=${host_ssl}"
    COMMAND_ERROR_IS_FATAL ANY)
  # cargo sets NUM_JOBS for build scripts.
  execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${host}" --target comp_err uca9dump
      --parallel $ENV{NUM_JOBS}
    COMMAND_ERROR_IS_FATAL ANY)
  set(tools "${host}/runtime_output_directory")

  add_executable(comp_err IMPORTED GLOBAL)
  set_target_properties(comp_err PROPERTIES IMPORTED_LOCATION "${tools}/comp_err")

  # CMake runs a target's CROSSCOMPILING_EMULATOR with the target's
  # executable and then its arguments, so drop the executable.
  file(WRITE "${host}/uca9dump.sh" "#!/bin/sh\nshift\nexec '${tools}/uca9dump' \"$@\"\n")
  file(CHMOD "${host}/uca9dump.sh" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
  set_property(TARGET uca9dump PROPERTY CROSSCOMPILING_EMULATOR "${host}/uca9dump.sh")
endfunction()
# The toolchain file is also read for try_compile() projects, which have no
# MySQL targets.
if(NOT CMAKE_PROJECT_NAME STREQUAL "CMAKE_TRY_COMPILE")
  cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}"
    CALL _quickinstall_mysql_host_tools)
endif()
