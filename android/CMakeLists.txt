cmake_minimum_required(VERSION 3.4.1)
project(Pitchy)

set (CMAKE_VERBOSE_MAKEFILE ON)
set (CMAKE_CXX_STANDARD 14)

add_library(react-native-pitchy            SHARED
            ../cpp/react-native-pitchy.cpp
            cpp-adapter.cpp
)

target_link_options(react-native-pitchy PRIVATE
            "-Wl,-z,max-page-size=16384"
            "-Wl,-z,common-page-size=16384"
)

# Specifies a path to native header files.
include_directories(
            ../cpp
)
