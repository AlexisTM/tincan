# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(tincan LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "tincan")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Build the tincan Go transport bridge, rebuilt whenever its sources change.
find_program(GO_EXECUTABLE go)
if(NOT GO_EXECUTABLE)
  message(FATAL_ERROR "go not found; the tincan bridge needs Go to build")
endif()
# cgo can't use MSVC; it needs a MinGW-w64 gcc or clang on PATH, or CC set.
if(NOT DEFINED ENV{CC})
  find_program(TINCAN_BRIDGE_GCC gcc)
  if(NOT TINCAN_BRIDGE_GCC)
    message(FATAL_ERROR "no C compiler for cgo; put MinGW-w64 gcc on PATH or set CC")
  endif()
endif()

if(NOT FLUTTER_TARGET_PLATFORM OR FLUTTER_TARGET_PLATFORM STREQUAL "windows-x64")
  set(TINCAN_BRIDGE_GOARCH "amd64")
elseif(FLUTTER_TARGET_PLATFORM STREQUAL "windows-arm64")
  set(TINCAN_BRIDGE_GOARCH "arm64")
else()
  message(FATAL_ERROR "unsupported target ${FLUTTER_TARGET_PLATFORM} for the tincan bridge")
endif()

set(TINCAN_BRIDGE_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../gobridge")
file(GLOB_RECURSE TINCAN_BRIDGE_DEPS CONFIGURE_DEPENDS
  "${TINCAN_BRIDGE_SRC}/*.go" "${TINCAN_BRIDGE_SRC}/go.mod" "${TINCAN_BRIDGE_SRC}/go.sum")
list(FILTER TINCAN_BRIDGE_DEPS EXCLUDE REGEX "_test\\.go$")
set(TINCAN_BRIDGE_DLL "${CMAKE_BINARY_DIR}/tincan_bridge/tincan_bridge.dll")
add_custom_command(
  OUTPUT "${TINCAN_BRIDGE_DLL}"
  COMMAND ${CMAKE_COMMAND} -E env CGO_ENABLED=1 GOOS=windows
    GOARCH=${TINCAN_BRIDGE_GOARCH}
    "${GO_EXECUTABLE}" build -trimpath -ldflags "-s -w" -buildmode=c-shared
    -o "${TINCAN_BRIDGE_DLL}" ./cshared
  WORKING_DIRECTORY "${TINCAN_BRIDGE_SRC}"
  DEPENDS ${TINCAN_BRIDGE_DEPS}
  COMMENT "Building tincan_bridge.dll (${TINCAN_BRIDGE_GOARCH})"
  VERBATIM)
add_custom_target(tincan_bridge ALL DEPENDS "${TINCAN_BRIDGE_DLL}")
add_dependencies(${BINARY_NAME} tincan_bridge)
install(FILES "${TINCAN_BRIDGE_DLL}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)
