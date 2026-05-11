cmake_minimum_required(VERSION 3.16)

project(VirtualVDP
    VERSION 0.1.0
    DESCRIPTION "A minimal LibVNCServer-based virtual display prototype"
    LANGUAGES C
)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

find_package(LibVNCServer REQUIRED)
if(LibVNCServer_FOUND)
	# libs and headers location are now accessible via properties, but you only
	# need to add the respective export target to your project's target_link_libraries,
	# cmake will automatically add libs and headers
	# eg: add client (YOUR_PROJECT_TARGET being a placeholder for your real target -
	# it must be defined by add_executable or add_library):
	target_link_libraries(VirtualVDP LibVNCServer::vncclient)
	# add server:
	target_link_libraries(VirtualVDP LibVNCServer::vncserver)
endif()

add_executable(virtual-vdp
    src/main.c
)

target_include_directories(virtual-vdp
    PRIVATE
        "${LibVNCServer_INCLUDE_DIR}"
)

target_link_libraries(virtual-vdp
    PRIVATE
        LibVNCServer::LibVNCServer
)

if(MSVC)
    target_compile_options(virtual-vdp PRIVATE /W4)
else()
    target_compile_options(virtual-vdp PRIVATE -Wall -Wextra -Wpedantic)
endif()
