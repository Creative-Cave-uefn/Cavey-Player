# Нативная библиотека Cavey Mix. Собирается Flutter'ом (windows/, linux/) или отдельно для тестов:
#   cmake -S packages/cave_mix/src -B build/cave_mix -DCM_BUILD_TESTS=ON && cmake --build build/cave_mix
cmake_minimum_required(VERSION 3.14)
project(cave_mix LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(CM_BUILD_TESTS "Собрать нативные тесты" OFF)

set(CM_SOURCES
  ${CMAKE_CURRENT_LIST_DIR}/engine.cpp
  ${CMAKE_CURRENT_LIST_DIR}/readers.cpp
  ${CMAKE_CURRENT_LIST_DIR}/analysis.cpp
  ${CMAKE_CURRENT_LIST_DIR}/third_party/miniaudio/miniaudio.c
  ${CMAKE_CURRENT_LIST_DIR}/third_party/rubberband/single/RubberBandSingle.cpp
)

function(cm_configure target)
  target_include_directories(${target} PUBLIC ${CMAKE_CURRENT_FUNCTION_LIST_DIR})
  target_compile_definitions(${target} PRIVATE
    MA_NO_ENCODING MA_NO_GENERATION MA_NO_ENGINE MA_NO_NODE_GRAPH MA_NO_RESOURCE_MANAGER
    _USE_MATH_DEFINES)
  if(MSVC)
    # исходники в UTF-8 (русские строки и комментарии)
    target_compile_options(${target} PRIVATE /utf-8 /W3 /O2)
    target_compile_definitions(${target} PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
  else()
    target_compile_options(${target} PRIVATE -O2 -Wall -Wno-unused-function -Wno-unused-variable)
    find_package(Threads REQUIRED)
    target_link_libraries(${target} PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
    if(NOT APPLE)
      target_link_libraries(${target} PRIVATE m)
    endif()
  endif()
  if(APPLE)
    target_link_libraries(${target} PRIVATE "-framework Accelerate" "-framework CoreAudio" "-framework AudioToolbox")
  endif()
endfunction()

add_library(cave_mix SHARED ${CM_SOURCES})
cm_configure(cave_mix)
set_target_properties(cave_mix PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  C_VISIBILITY_PRESET hidden
  OUTPUT_NAME "cave_mix")
target_compile_definitions(cave_mix PUBLIC DART_SHARED_LIB)

if(CM_BUILD_TESTS)
  add_library(cave_mix_static STATIC ${CM_SOURCES})
  cm_configure(cave_mix_static)
  add_executable(cave_mix_tests ${CMAKE_CURRENT_LIST_DIR}/tests/engine_tests.cpp)
  add_executable(cave_mix_analysis_tests ${CMAKE_CURRENT_LIST_DIR}/tests/analysis_tests.cpp)
  target_link_libraries(cave_mix_analysis_tests PRIVATE cave_mix_static)
  if(NOT MSVC)
    target_link_libraries(cave_mix_analysis_tests PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
  endif()
  target_link_libraries(cave_mix_tests PRIVATE cave_mix_static)
  if(NOT MSVC)
    target_link_libraries(cave_mix_tests PRIVATE Threads::Threads ${CMAKE_DL_LIBS} m)
  endif()
endif()
