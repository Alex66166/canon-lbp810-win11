cmake_minimum_required(VERSION 3.21)
cmake_policy(SET CMP0091 NEW)
project(lbp810_bridge LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

include(FetchContent)
set(LIBCAPT_INSTALL OFF CACHE BOOL "" FORCE)
set(LIBCAPT_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LIBCAPT_BUILD_TESTS OFF CACHE BOOL "" FORCE)
FetchContent_Declare(libcapt
    GIT_REPOSITORY https://github.com/darkvision77/libcapt.git
    GIT_TAG 8f1fd502e6fee893d409f09c5895248c189ead4b
    GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(libcapt)

add_executable(lbp810-bridge main.cpp)
target_link_libraries(lbp810-bridge PRIVATE libcapt::libcapt setupapi)
target_compile_definitions(lbp810-bridge PRIVATE WIN32_LEAN_AND_MEAN NOMINMAX UNICODE _UNICODE)
if(MSVC)
    target_compile_options(lbp810-bridge PRIVATE /W4 /EHsc /utf-8)
endif()
