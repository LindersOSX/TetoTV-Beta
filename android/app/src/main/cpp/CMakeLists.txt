cmake_minimum_required(VERSION 3.22.1)

project(tetotv_discord LANGUAGES CXX)

find_package(discord_partner_sdk REQUIRED CONFIG)

add_library(tetotv_discord SHARED discord_rich_presence.cpp)

target_compile_features(tetotv_discord PRIVATE cxx_std_20)
target_compile_options(tetotv_discord PRIVATE -Wall -Wextra -Werror=return-type)

# NDK r28 already emits 16 KiB LOAD alignment for arm64-v8a, but its ARMv7
# default remains 4 KiB. Raise only the ABI that needs it so the compliant
# ARM64 layout is left unchanged.
if(ANDROID_ABI STREQUAL "armeabi-v7a")
    target_link_options(
        tetotv_discord
        PRIVATE
        "-Wl,-z,common-page-size=16384"
        "-Wl,-z,max-page-size=16384"
    )
endif()

target_link_libraries(
    tetotv_discord
    PRIVATE
    discord_partner_sdk::discord_partner_sdk
    android
    log
)
