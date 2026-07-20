# User CMake customization for the IOController MPLAB "iocontroller" config.
#
# Keep this outside .generated/ so MPLAB regeneration does not overwrite it.

get_filename_component(_ioc_project_dir
    "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(_ioc_include_dir "${_ioc_project_dir}/include")
set(_ioc_root_stub_main "${_ioc_project_dir}/main.c")

foreach(_ioc_target
        IOController_iocontroller_default_XC8_compile
        IOController_iocontroller_default_XC8_assemble
        IOController_iocontroller_default_XC8_assemblePreprocess)
    if(TARGET ${_ioc_target})
        target_include_directories(${_ioc_target} PRIVATE "${_ioc_include_dir}")
    endif()
endforeach()

if(TARGET IOController_iocontroller_default_XC8_compile)
    get_target_property(_ioc_sources
        IOController_iocontroller_default_XC8_compile SOURCES)
    if(_ioc_sources)
        list(REMOVE_ITEM _ioc_sources "${_ioc_root_stub_main}")
        set_target_properties(IOController_iocontroller_default_XC8_compile
            PROPERTIES SOURCES "${_ioc_sources}")
    endif()
endif()
