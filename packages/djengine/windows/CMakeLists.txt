cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "djengine")
project(${PROJECT_NAME} LANGUAGES CXX)

# Звуковой движок DJ-пульта: обычная динамическая библиотека, которую Dart вызывает через FFI
add_library(${PROJECT_NAME} SHARED "../src/djengine.cpp")
target_compile_features(${PROJECT_NAME} PRIVATE cxx_std_17)
set_target_properties(${PROJECT_NAME} PROPERTIES OUTPUT_NAME "djengine")
# NOMINMAX: windows.h (его подключает miniaudio) иначе подменяет std::min и std::max
target_compile_definitions(${PROJECT_NAME} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _USE_MATH_DEFINES)

# Список библиотек, которые Flutter положит рядом с программой
set(djengine_bundled_libraries
  "$<TARGET_FILE:${PROJECT_NAME}>"
  PARENT_SCOPE
)
