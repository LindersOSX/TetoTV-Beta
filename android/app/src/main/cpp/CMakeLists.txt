cmake_minimum_required(VERSION 3.22.1)

project(tetotv_discord LANGUAGES CXX)

find_package(discord_partner_sdk REQUIRED CONFIG)

add_library(tetotv_discord SHARED discord_rich_presence.cpp)

target_compile_features(tetotv_discord PRIVATE cxx_std_20)
target_compile_options(tetotv_discord PRIVATE -Wall -Wextra -Werror=return-type)

target_link_libraries(
    tetotv_discord
    PRIVATE
    discord_partner_sdk::discord_partner_sdk
    android
    log
)
