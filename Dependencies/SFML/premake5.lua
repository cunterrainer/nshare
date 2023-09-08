project "SFML-Network"
    kind "StaticLib"
    language "C++"
    staticruntime "on"

    defines {
        "SFML_STATIC",
        "UNICODE"
    }

    files {
        "src/SFML/Network/*.cpp",
        "src/SFML/Network/*.hpp",
        "src/SFML/System/*.cpp",
        "src/SFML/System/*.hpp",
        "include/SFML/System/*.hpp",
        "include/SFML/Network/*.hpp",
        "include/SFML/*.hpp"
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

    includedirs {
        "include",
        "src",
        -- "extlibs/headers",
        -- "extlibs/headers/AL",
        -- "extlibs/headers/freetype2",
        -- "extlibs/headers/stb_image"
    }
