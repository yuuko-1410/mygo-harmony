cmake_minimum_required(VERSION 3.5.0)
project(mygo)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH})

# The app's c-archive, built by `go build -buildmode=c-archive`.
add_library(app STATIC IMPORTED)
set_target_properties(app PROPERTIES IMPORTED_LOCATION ${NATIVERENDER_ROOT_PATH}/libapp.a)

add_library(entry SHARED napi_init.cpp)

target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libace_ndk.z.so
    libnative_window.so
    libnative_drawing.so
    libnative_vsync.so
    libnative_buffer.so
    libEGL.so
    libGLESv3.so
    app)
