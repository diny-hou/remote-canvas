cmake_minimum_required(VERSION 3.20)
project(RemoteCanvasHost VERSION 0.1.0 LANGUAGES CXX)

add_executable(remote_canvas_host
    src/main.cpp
    src/host.cpp
)

target_include_directories(remote_canvas_host PRIVATE include)
target_compile_features(remote_canvas_host PRIVATE cxx_std_20)

if(MSVC)
    target_compile_options(remote_canvas_host PRIVATE /W4 /permissive-)
else()
    target_compile_options(remote_canvas_host PRIVATE -Wall -Wextra -Wpedantic)
endif()
