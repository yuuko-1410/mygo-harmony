cmake_minimum_required(VERSION 3.5.0)
project(mygoohos)

set(CMAKE_CXX_STANDARD 17)

add_library(entry SHARED napi_init.cpp)

# The MyGo app, built by the ohos-go toolchain as a c-archive.
target_link_libraries(entry PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/libapp.a
    libace_napi.z.so
    libhilog_ndk.z.so
    libace_ndk.z.so
    libnative_window.so
    libnative_drawing.so
    libnative_vsync.so
    libnative_buffer.so
    libEGL.so
    libGLESv3.so
)

target_link_options(entry PRIVATE -Wl,--no-undefined-version)
