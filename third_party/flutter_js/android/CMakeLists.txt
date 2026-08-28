cmake_minimum_required(VERSION 3.22.1)
project(tetotv_quickjs_runtime LANGUAGES C CXX)

add_library(
    fastdev_quickjs_runtime
    SHARED
    src/main/c/quickjs_runtime.cpp
    src/main/c/quickjs/cutils.c
    src/main/c/quickjs/dtoa.c
    src/main/c/quickjs/libregexp.c
    src/main/c/quickjs/libunicode.c
    src/main/c/quickjs/quickjs.c
)

target_include_directories(
    fastdev_quickjs_runtime
    PRIVATE src/main/c/quickjs
)

target_compile_features(fastdev_quickjs_runtime PRIVATE cxx_std_17)
target_compile_definitions(
    fastdev_quickjs_runtime
    PRIVATE
    _GNU_SOURCE
    CONFIG_VERSION="2026-06-04"
)

# Android 15+ devices may use a 16 KiB memory page size. These options keep
# the native runtime loadable on both 4 KiB and 16 KiB devices.
target_link_options(
    fastdev_quickjs_runtime
    PRIVATE
    "-Wl,-z,common-page-size=16384"
    "-Wl,-z,max-page-size=16384"
)

find_library(log-lib log)
find_library(m-lib m)
target_link_libraries(fastdev_quickjs_runtime PRIVATE ${log-lib} ${m-lib})
