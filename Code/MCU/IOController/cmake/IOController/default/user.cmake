# User CMake customization for the IOController MPLAB project.
#
# The MPLAB-generated build (.generated/rule.cmake) does not place the project's
# include/ directory on the compiler search path, so project headers such as
# "config.h" and "external_sync.h" fail with "file not found".  (The hand Makefile works
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
get_filename_component(_ioc_project_dir
    "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(_ioc_controller_latch_source
    "${_ioc_project_dir}/src/controller_latch.c")

foreach(_ioc_target
        IOController_default_default_XC8_compile
        IOController_default_default_XC8_assemble
        IOController_default_default_XC8_assemblePreprocess)
    if(TARGET ${_ioc_target})
        target_include_directories(${_ioc_target} PRIVATE "${_ioc_include_dir}")
    endif()
endforeach()

# Keep project source additions in the persistent user hook because MPLAB
# regenerates the source list under .generated/.
#
# controller_latch.c is a REAL output driver, not a diagnostic: it owns the
# 74HC595 pair and parks it at a known state on boot.  Only the optional
# incrementing-counter pattern inside it is diagnostic, and that is compiled out
# unless CONTROLLER_LATCH_COUNTER_TEST is set.  The old wording said "diagnostic
# driver sources", which invited deleting a driver the hardware depends on.
if(TARGET IOController_default_default_XC8_compile)
    get_target_property(_ioc_sources
        IOController_default_default_XC8_compile SOURCES)
    list(FIND _ioc_sources "${_ioc_controller_latch_source}"
        _ioc_controller_latch_index)
    if(_ioc_controller_latch_index EQUAL -1)
        target_sources(IOController_default_default_XC8_compile PRIVATE
            "${_ioc_controller_latch_source}")
    endif()
endif()
