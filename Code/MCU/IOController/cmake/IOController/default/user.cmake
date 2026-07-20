# User CMake customization for the IOController MPLAB project.
#
# The MPLAB-generated build (.generated/rule.cmake) does not place the project's
# include/ directory on the compiler search path, so every  #include "config.h"
# / "trace.h" / "sdlc.h"  fails with "file not found".  (The hand Makefile works
# because it passes -Iinclude; the CMake/MPLAB build had no equivalent.)
#
# This is the sanctioned customization hook: CMakeLists.txt includes it if
# present, and MPLAB only overwrites .generated/*, so this survives regeneration.
#
# GUI equivalent: MPLAB project properties -> XC8 compiler -> include
# directories; setting it there would regenerate rule.cmake with the -I and make
# this file unnecessary.

get_filename_component(_ioc_include_dir
    "${CMAKE_CURRENT_LIST_DIR}/../../../include" ABSOLUTE)

foreach(_ioc_target
        IOController_default_default_XC8_compile
        IOController_default_default_XC8_assemble
        IOController_default_default_XC8_assemblePreprocess)
    if(TARGET ${_ioc_target})
        target_include_directories(${_ioc_target} PRIVATE "${_ioc_include_dir}")
    endif()
endforeach()
