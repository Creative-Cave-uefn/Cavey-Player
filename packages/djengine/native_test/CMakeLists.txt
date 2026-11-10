# Проверки движка на компьютере разработчика (без звуковой карты): cmake -S . -B build && cmake --build build && ./build/engine_test
cmake_minimum_required(VERSION 3.14)
project(djengine_test CXX)
set(CMAKE_CXX_STANDARD 17)
add_executable(engine_test engine_test.cpp ../src/djengine.cpp)
target_compile_definitions(engine_test PRIVATE DJ_NO_DEVICE)
target_compile_options(engine_test PRIVATE -O2 -Wall -Wextra)
