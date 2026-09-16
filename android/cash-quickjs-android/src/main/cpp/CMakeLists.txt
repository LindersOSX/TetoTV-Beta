cmake_minimum_required(VERSION 3.22.1)

project(cash_quickjs_android LANGUAGES C CXX)

if(NOT DEFINED QUICKJS_SOURCE_ROOT OR NOT IS_DIRECTORY "${QUICKJS_SOURCE_ROOT}")
    message(FATAL_ERROR "The reviewed Cash App QuickJS source tree is missing")
endif()
if(NOT DEFINED QUICKJS_VERSION OR QUICKJS_VERSION STREQUAL "")
    message(FATAL_ERROR "The reviewed Cash App QuickJS version is missing")
endif()

set(CMAKE_C_STANDARD 99)
set(CMAKE_CXX_STANDARD 11)

set(
    QUICKJS_SOURCES
    "${QUICKJS_SOURCE_ROOT}/Context.cpp"
    "${QUICKJS_SOURCE_ROOT}/ExceptionThrowers.cpp"
    "${QUICKJS_SOURCE_ROOT}/JavaMethodProxy.cpp"
    "${QUICKJS_SOURCE_ROOT}/JavaObjectProxy.cpp"
    "${QUICKJS_SOURCE_ROOT}/JsMethodProxy.cpp"
    "${QUICKJS_SOURCE_ROOT}/JsObjectProxy.cpp"
    "${QUICKJS_SOURCE_ROOT}/quickjs-jni.cpp"
    "${QUICKJS_SOURCE_ROOT}/quickjs/cutils.c"
    "${QUICKJS_SOURCE_ROOT}/quickjs/libregexp.c"
    "${QUICKJS_SOURCE_ROOT}/quickjs/libunicode.c"
    "${QUICKJS_SOURCE_ROOT}/quickjs/quickjs.c"
)

add_library(quickjs SHARED ${QUICKJS_SOURCES})
target_compile_definitions(quickjs PRIVATE CONFIG_VERSION="${QUICKJS_VERSION}")

# Android 15+ devices may use 16 KiB memory pages. These options preserve the
# app.cash.quickjs JNI ABI while rebuilding the pinned 0.9.2 implementation so
# each ELF LOAD segment is valid on both 4 KiB and 16 KiB devices.
target_link_options(
    quickjs
    PRIVATE
    "-Wl,-z,common-page-size=16384"
    "-Wl,-z,max-page-size=16384"
)
