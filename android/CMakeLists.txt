cmake_minimum_required(VERSION 3.10)

project(sound_link LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SOUND_LINK_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../src")

add_library(sound_link SHARED
  "${SOUND_LINK_CORE_DIR}/sound_link_core.cpp"
  "${SOUND_LINK_CORE_DIR}/ggwave/src/ggwave.cpp"
  "src/main/cpp/sound_link_jni.cpp"
)

target_include_directories(sound_link PRIVATE
  "${SOUND_LINK_CORE_DIR}"
  "${SOUND_LINK_CORE_DIR}/ggwave/include"
)

target_compile_definitions(sound_link PRIVATE GGWAVE_DISABLE_LOG)
target_compile_options(sound_link PRIVATE -O2 -fvisibility=hidden)
target_link_options(sound_link PRIVATE "-Wl,-z,max-page-size=16384")
