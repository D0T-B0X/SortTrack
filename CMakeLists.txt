cmake_minimum_required(VERSION 3.24)

if(NOT DEFINED CMAKE_HIP_ARCHITECTURES)
  set(CMAKE_HIP_ARCHITECTURES gfx1100)
endif()

project(SortTrack LANGUAGES CXX HIP)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Release" "RelWithDebInfo" "MinSizeRel")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_HIP_STANDARD 17)

find_package(hip REQUIRED)
find_package(rocprim REQUIRED)

add_library(onesweep STATIC lib/onesweep.hip)
target_include_directories(onesweep PUBLIC lib)
target_link_libraries(onesweep PUBLIC hip::host)
target_link_libraries(onesweep PRIVATE roc::rocprim_hip)

add_executable(${PROJECT_NAME}_test Tests/test.cpp)
target_include_directories(${PROJECT_NAME}_test PRIVATE Tests)
target_link_libraries(${PROJECT_NAME}_test PRIVATE onesweep)
target_compile_definitions(${PROJECT_NAME}_test PRIVATE
  TEST_CSV_PATH="${CMAKE_CURRENT_SOURCE_DIR}/Tests/tests.csv")