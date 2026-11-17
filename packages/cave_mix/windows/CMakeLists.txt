# Flutter собирает нативную часть плагина этим файлом и кладёт cave_mix.dll рядом с .exe
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "cave_mix")
project(${PROJECT_NAME} LANGUAGES C CXX)

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" "${CMAKE_CURRENT_BINARY_DIR}/shared")

set(cave_mix_bundled_libraries
  $<TARGET_FILE:cave_mix>
  PARENT_SCOPE
)
