include(FindPackageHandleStandardArgs)

find_package(PkgConfig QUIET)

if(PkgConfig_FOUND)
    pkg_check_modules(PC_LIBVNCSERVER QUIET libvncserver)
endif()

find_path(LibVNCServer_INCLUDE_DIR
    NAMES rfb/rfb.h
    HINTS ${PC_LIBVNCSERVER_INCLUDE_DIRS}
)

find_library(LibVNCServer_LIBRARY
    NAMES vncserver libvncserver
    HINTS ${PC_LIBVNCSERVER_LIBRARY_DIRS}
)

find_package_handle_standard_args(LibVNCServer
    REQUIRED_VARS LibVNCServer_INCLUDE_DIR LibVNCServer_LIBRARY
)

if(LibVNCServer_FOUND AND NOT TARGET LibVNCServer::LibVNCServer)
    add_library(LibVNCServer::LibVNCServer UNKNOWN IMPORTED)
    set_target_properties(LibVNCServer::LibVNCServer PROPERTIES
        IMPORTED_LOCATION "${LibVNCServer_LIBRARY}"
        INTERFACE_INCLUDE_DIRECTORIES "${LibVNCServer_INCLUDE_DIR}"
    )

    if(PC_LIBVNCSERVER_FOUND)
        set_property(TARGET LibVNCServer::LibVNCServer APPEND PROPERTY
            INTERFACE_COMPILE_OPTIONS "${PC_LIBVNCSERVER_CFLAGS_OTHER}"
        )
        set_property(TARGET LibVNCServer::LibVNCServer APPEND PROPERTY
            INTERFACE_LINK_LIBRARIES "${PC_LIBVNCSERVER_LINK_LIBRARIES}"
        )
        set_property(TARGET LibVNCServer::LibVNCServer APPEND PROPERTY
            INTERFACE_LINK_OPTIONS "${PC_LIBVNCSERVER_LDFLAGS_OTHER}"
        )
    endif()
endif()

mark_as_advanced(LibVNCServer_INCLUDE_DIR LibVNCServer_LIBRARY)
