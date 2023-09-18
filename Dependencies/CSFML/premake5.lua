project "CSFML-Network"
    kind "StaticLib"
    language "C++"
    staticruntime "on"
    warnings "off"

    defines {
        "SFML_STATIC",
        "UNICODE"
    }

    files {
        "src/SFML/Network/*.cpp",
        "src/SFML/Network/*.h",
        "src/SFML/System/*.cpp",
        "src/SFML/System/*.h",
        "include/SFML/System/*.h",
        "include/SFML/Network/*.h",
        "include/SFML/*.h"
    }

    includedirs {
        "include",
        "src",
        "../SFML/include"
        -- "extlibs/headers",
        -- "extlibs/headers/AL",
        -- "extlibs/headers/freetype2",
        -- "extlibs/headers/stb_image"
    }

    filter "system:windows"
        files {
            "src/SFML/Network/Win32/*.cpp",
            "src/SFML/System/Win32/*.cpp",
            "src/SFML/System/Win32/*.hpp"
        }

    filter "system:linux or system:macosx"
        files {
            "src/SFML/Network/Unix/*.cpp",
            "src/SFML/System/Unix/*.cpp",
            "src/SFML/System/Unix/*.hpp"
        }
