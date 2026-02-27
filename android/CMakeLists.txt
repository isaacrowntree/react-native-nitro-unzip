cmake_minimum_required(VERSION 3.9.0)
project(NitroUnzip)

# C++ 20 required by Nitro
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Define the C++ library
add_library(
  NitroUnzip
  SHARED
  src/main/cpp/cpp-adapter.cpp
)

# Include Nitrogen generated sources + link NitroModules
include(${CMAKE_SOURCE_DIR}/../nitrogen/generated/android/NitroUnzip+autolinking.cmake)
