cmake_minimum_required(VERSION 3.16)

project(VirtualVDP
    VERSION 0.1.0
    DESCRIPTION "A minimal virtual TMS9918 display prototype"
    LANGUAGES C
)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

find_package(Threads REQUIRED)
find_package(LibVNCServer REQUIRED)

set(VIRTUAL_VDP_EXTERNAL_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/external"
    CACHE PATH
    "Local directory containing external headers and libraries"
)
set(VIRTUAL_VDP_EXTERNAL_INCLUDE_DIR
    "${VIRTUAL_VDP_EXTERNAL_DIR}/include"
    CACHE PATH
    "Local directory containing external headers"
)
set(VIRTUAL_VDP_EXTERNAL_LIBRARY_DIR
    "${VIRTUAL_VDP_EXTERNAL_DIR}/vrEmuTMS9918/lib"
    CACHE PATH
    "Local directory containing external libraries"
)
set(VIRTUAL_VDP_EXTERNAL_LIBRARIES
    ""
    CACHE STRING
    "Semicolon-separated external libraries to link, for example: vncserver;z"
)
set(VIRTUAL_VDP_VREmuTMS9918_LIBRARY
    "${VIRTUAL_VDP_EXTERNAL_LIBRARY_DIR}/libvrEmuTms9918.so"
    CACHE FILEPATH
    "Path to the vrEmuTms9918 shared library"
)

set(VIRTUAL_VDP_VDRIP9928_LIBRARY_DIR
    "${VIRTUAL_VDP_EXTERNAL_DIR}/vDrip9928/lib"
    CACHE PATH
    "Directory containing the vdrip_vdp shared libraries"
)

set(VIRTUAL_VDP_VDRIP9928_INCLUDE_DIR
    "${VIRTUAL_VDP_EXTERNAL_DIR}/vDrip9928/include"
    CACHE PATH
    "Directory containing the vdrip_vdp header"
)

add_executable(virtual-vdp
    src/app_config.c
    src/app_runtime.c
    src/main.c
    src/display_libvncserver.c
    src/input_keyboard.c
    src/keyboard_transport.c
    src/packet_dispatch.c
    src/packet_parser.c
    src/packet_replay.c
    src/protocol.c
    src/protocol_debug.c
    src/serial_port.c
    src/serial_reader.c
    src/video_device.c
    src/video_device_tms9928.c
    src/video_device_vdrip9928.c
    src/virtual_text_cursor.c
)

target_include_directories(virtual-vdp
    PRIVATE
        "${VIRTUAL_VDP_EXTERNAL_DIR}/vrEmuTMS9918/include"
        "${VIRTUAL_VDP_VDRIP9928_INCLUDE_DIR}"
)

target_link_directories(virtual-vdp
    PRIVATE
        "${VIRTUAL_VDP_EXTERNAL_LIBRARY_DIR}"
)

if(EXISTS "${VIRTUAL_VDP_VREmuTMS9918_LIBRARY}")
    target_link_libraries(virtual-vdp
        PRIVATE
            "${VIRTUAL_VDP_VREmuTMS9918_LIBRARY}"
            "${VIRTUAL_VDP_VDRIP9928_LIBRARY_DIR}/libvdrip_vdp.so"
            "${VIRTUAL_VDP_VDRIP9928_LIBRARY_DIR}/libvdrip_vdp_util.so"
            LibVNCServer::LibVNCServer
            Threads::Threads
    )
else()
    message(FATAL_ERROR "vrEmuTms9918 library not found: ${VIRTUAL_VDP_VREmuTMS9918_LIBRARY}")
endif()

if(VIRTUAL_VDP_EXTERNAL_LIBRARIES)
    target_link_libraries(virtual-vdp
        PRIVATE
            ${VIRTUAL_VDP_EXTERNAL_LIBRARIES}
    )
endif()

set_target_properties(virtual-vdp PROPERTIES
    BUILD_RPATH "${VIRTUAL_VDP_EXTERNAL_LIBRARY_DIR};${VIRTUAL_VDP_VDRIP9928_LIBRARY_DIR}"
)

if(MSVC)
    target_compile_options(virtual-vdp PRIVATE /W4)
else()
    target_compile_options(virtual-vdp PRIVATE -Wall -Wextra -Wpedantic)
endif()
