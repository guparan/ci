#!/bin/bash
set -o errexit # Exit on error

# Here we pick what gets to be compiled. The role of this script is to
# call cmake with the appropriate options. After this, the build
# directory should be ready to run 'make'.

## Significant environnement variables:
# - CI_JOB                    (e.g. ubuntu_gcc-4.8_options)
# - CI_OPTIONS                if contains "options" then activate plugins
# - CI_CMAKE_OPTIONS          (additional arguments to pass to cmake)
# - ARCHITECTURE = x86 | amd64     (for Windows builds)
# - BUILD_TYPE             Debug|Release
# - CC and CXX
# - COMPILER               # important for Visual Studio paths (VS-2012, VS-2013 or VS-2015)


## Checks

usage() {
    echo "Usage: configure.sh <build-dir> <src-dir> <compiler> <architecture> <build-type> <build-options>"
}

if [ "$#" -eq 6 ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    . "$SCRIPT_DIR"/utils.sh

    BUILD_DIR="$(cd "$1" && pwd)"
    if vm-is-windows; then
        # pwd with a Windows format (c:/ instead of /c/)
        SRC_DIR="$(cd "$2" && pwd -W)"
    else
        SRC_DIR="$(cd "$2" && pwd)"
    fi
    COMPILER="$3"
    ARCHITECTURE="$4"
    BUILD_TYPE="$5"
    BUILD_OPTIONS="$6"
else
    usage; exit 1
fi

if [[ ! -d "$SRC_DIR/applications/plugins" ]]; then
    echo "Error: '$SRC_DIR' does not look like a SOFA source tree."
    usage; exit 1
fi

cd "$SRC_DIR"



########
# Init #
########

# Get Windows dependency pack
if vm-is-windows && [ ! -d "$SRC_DIR/lib" ]; then
    echo "Copying dependency pack in the source tree."
    curl -L "https://www.sofa-framework.org/download/WinDepPack/$COMPILER/latest" --output dependencies_tmp.zip
    unzip dependencies_tmp.zip -d dependencies_tmp > /dev/null
    cp -rf dependencies_tmp/*/* "$SRC_DIR"
    rm -rf dependencies_tmp*
fi

# Choose between incremental build and full build
full_build=""
sha=$(git --git-dir="$SRC_DIR/.git" rev-parse HEAD)

if in-array "force-full-build" "$BUILD_OPTIONS"; then
    full_build="Full build forced."
elif [ ! -e "$BUILD_DIR/CMakeCache.txt" ]; then
    full_build="No previous build detected."
elif [ ! -e "$BUILD_DIR/last-commit-built.txt" ]; then
    full_build="Last build's commit not found."
else
    # Sometimes, a change in a cmake script can cause an incremental
    # build to fail, so let's be extra cautious and make a full build
    # each time a .cmake file changes.
    last_commit_build="$(cat "$BUILD_DIR/last-commit-built.txt")"
    if git --git-dir="$SRC_DIR/.git" diff --name-only "$last_commit_build" "$sha" | grep 'cmake/.*\.cmake' ; then
        full_build="Detected changes in a CMake script file."
    fi
fi

if [ -n "$full_build" ]; then
    echo "Starting a full build. ($full_build)"
    # '|| true' is an ugly workaround, because rm sometimes fails to remove the
    # build directory on the Windows slaves, for reasons unknown yet.
    rm -rf "$BUILD_DIR" || true
    mkdir -p "$BUILD_DIR"
    # Flag. E.g. we check this before counting compiler warnings,
    # which is not relevant after an incremental build.
    touch "$BUILD_DIR/full-build"
    echo "$sha" > "$BUILD_DIR/last-commit-built.txt"
else
    rm -f "$BUILD_DIR/full-build"
    echo "Starting an incremental build"
fi



#################
# CMake options #
#################

cmake_options=""
add-cmake-option() {
    cmake_options="$cmake_options $*"
}

# Compiler and cache
if vm-is-windows; then
    # Compiler
    # see comntools usage in call-cmake() for compiler selection on Windows

    # Cache
    if [ -n "$VM_CLCACHE_PATH" ]; then
        add-cmake-option "-DCMAKE_C_COMPILER=$VM_CLCACHE_PATH/bin/clcache.bat"
        add-cmake-option "-DCMAKE_CXX_COMPILER=$VM_CLCACHE_PATH/bin/clcache.bat"
    fi
else
    # Compiler
    case "$COMPILER" in
        gcc*)
            c_compiler="gcc"
            cxx_compiler="g++"
        ;;
        clang*)
            c_compiler="clang"
            cxx_compiler="clang++"
        ;;
        *) # other
            echo "Unknown compiler: $COMPILER"
            echo "Try a lucky guess..."
            c_compiler="$COMPILER"
            cxx_compiler="${COMPILER}++"
        ;;
    esac
    add-cmake-option "-DCMAKE_C_COMPILER=$c_compiler"
    add-cmake-option "-DCMAKE_CXX_COMPILER=$cxx_compiler"

    # Cache
    if [ -x "$(command -v ccache)" ]; then
        export PATH="/usr/lib/ccache:$PATH" # /usr/lib/ccache contains symlinks for every compiler
    fi
fi

# Options common to all configurations
add-cmake-option "-DCMAKE_BUILD_TYPE=${BUILD_TYPE^}"
add-cmake-option "-DCMAKE_COLOR_MAKEFILE=OFF"
add-cmake-option "-DSOFA_BUILD_TUTORIALS=OFF"
add-cmake-option "-DSOFA_BUILD_TESTS=ON"
add-cmake-option "-DPLUGIN_SOFAPYTHON=ON"

# Handle custom lib dirs
if vm-is-windows; then
    msvc_year="$(get-msvc-year $COMPILER)"
    msvc_version="$(get-compiler-version $COMPILER)"
    qt_compiler="msvc-${msvc_year}"
    boost_compiler="msvc-${msvc_version}"
else
    qt_compiler="$(cut -d "-" -f 1 <<< "$COMPILER")" # gcc-4.8 -> gcc
fi
if [[ "$ARCHITECTURE" == "amd64" ]]; then
    qt_lib="${qt_compiler}_64/lib"
    boost_lib="lib64-${boost_compiler}"
else
    qt_lib="${qt_compiler}/lib"
    boost_lib="lib32-${boost_compiler}"
fi
if [ -d "$VM_QT_PATH" ]; then
    add-cmake-option "-DQt5_DIR=$VM_QT_PATH/${qt_lib}/cmake/Qt5"
fi
if [ -d "$VM_BOOST_PATH" ] && vm-is-windows; then # VM_BOOST_PATH is effective on Windows only
    add-cmake-option "-DBOOST_ROOT=$VM_BOOST_PATH"
    add-cmake-option "-DBOOST_LIBRARYDIR=$VM_BOOST_PATH/${boost_lib}"
fi
if [ -d "$VM_PYTHON_PATH" ] && vm-is-windows; then # VM_PYTHON_PATH is effective on Windows only
    add-cmake-option "-DPYTHON_LIBRARY=$VM_PYTHON_PATH/libs/python27.lib"
    add-cmake-option "-DPYTHON_INCLUDE_DIR=$VM_PYTHON_PATH/include"
fi

# "build-all-plugins" specific options
if in-array "build-all-plugins" "$BUILD_OPTIONS"; then
    # Build with as many options enabled as possible
    add-cmake-option "-DSOFA_BUILD_METIS=ON"
    add-cmake-option "-DSOFA_BUILD_ARTRACK=ON"
    add-cmake-option "-DSOFA_BUILD_MINIFLOWVR=ON"

    ### Plugins
    add-cmake-option "-DPLUGIN_ARTRACK=ON"
    if [ -d "$VM_BULLET_PATH" ]; then
        add-cmake-option "-DBullet_DIR=$VM_BULLET_PATH"
        add-cmake-option "-DPLUGIN_BULLETCOLLISIONDETECTION=ON"
    else
        add-cmake-option "-DPLUGIN_BULLETCOLLISIONDETECTION=OFF"
    fi
    # Missing CGAL library
    if [[ "$VM_HAS_CGAL" == "true" ]]; then
        add-cmake-option "-DPLUGIN_CGALPLUGIN=ON"
    else
        add-cmake-option "-DPLUGIN_CGALPLUGIN=OFF"
    fi
    if [[ "$VM_HAS_ASSIMP" == "true" ]] || vm-is-windows; then
        # INFO: ColladaSceneLoader contains assimp for Windows (but that does not mean that VM has Assimp)
        add-cmake-option "-DPLUGIN_COLLADASCENELOADER=ON"
    else
        add-cmake-option "-DPLUGIN_COLLADASCENELOADER=OFF"
    fi
    add-cmake-option "-DPLUGIN_COMPLIANT=ON"
    add-cmake-option "-DPLUGIN_EXTERNALBEHAVIORMODEL=ON"
    add-cmake-option "-DPLUGIN_FLEXIBLE=ON"
    # Requires specific libraries.
    add-cmake-option "-DPLUGIN_HAPTION=OFF"
    add-cmake-option "-DPLUGIN_IMAGE=ON"
    add-cmake-option "-DPLUGIN_INVERTIBLEFVM=ON"
    add-cmake-option "-DPLUGIN_MANIFOLDTOPOLOGIES=ON"
    add-cmake-option "-DPLUGIN_MANUALMAPPING=ON"
    if [[ "$VM_HAS_OPENCASCADE" == "true" ]]; then
        add-cmake-option "-DPLUGIN_MESHSTEPLOADER=ON"
    else
        add-cmake-option "-DPLUGIN_MESHSTEPLOADER=OFF"
    fi
    add-cmake-option "-DPLUGIN_MULTITHREADING=ON"
    add-cmake-option "-DPLUGIN_OPTITRACKNATNET=ON"
    # Does not compile, but it just needs to be updated.
    add-cmake-option "-DPLUGIN_PERSISTENTCONTACT=OFF"
    add-cmake-option "-DPLUGIN_PLUGINEXAMPLE=ON"
    add-cmake-option "-DPLUGIN_REGISTRATION=ON"
    # Requires OpenHaptics libraries.
    add-cmake-option "-DPLUGIN_SENSABLE=OFF"
    add-cmake-option "-DPLUGIN_SENSABLEEMULATION=ON"

    # Requires Sixense libraries.
    add-cmake-option "-DPLUGIN_SIXENSEHYDRA=OFF"
    add-cmake-option "-DPLUGIN_SOFACARVING=ON"
    if [[ "$VM_HAS_CUDA" == "true" ]]; then
        add-cmake-option "-DPLUGIN_SOFACUDA=ON"
    else
        add-cmake-option "-DPLUGIN_SOFACUDA=OFF"
    fi
    # Requires HAPI libraries.
    add-cmake-option "-DPLUGIN_SOFAHAPI=OFF"
    # Not sure if worth maintaining
    add-cmake-option "-DPLUGIN_SOFASIMPLEGUI=ON"
    add-cmake-option "-DPLUGIN_THMPGSPATIALHASHING=ON"
    # Requires XiRobot library.
    add-cmake-option "-DPLUGIN_XITACT=OFF"
    add-cmake-option "-DPLUGIN_RIGIDSCALE=ON"
fi

# Options passed via the environnement
if [ -n "$CI_CMAKE_OPTIONS" ]; then
    add-cmake-option "$CI_CMAKE_OPTIONS"
fi



#############
# Configure #
#############

generator() {
    if [ -x "$(command -v ninja)" ]; then
        echo "Ninja"
    elif vm-is-windows; then
        echo "\"NMake Makefiles\""
    else
        echo "Unix Makefiles"
    fi
}

call-cmake() {
    if vm-is-windows; then
        msvc_comntools="$(get-msvc-comntools $COMPILER)"
        # Call vcvarsall.bat first to setup environment
        vcvarsall="call \"%${msvc_comntools}%\\..\\..\\VC\vcvarsall.bat\" $ARCHITECTURE"
        echo "Calling $COMSPEC /c \"$vcvarsall & cmake $*\""
        $COMSPEC /c "$vcvarsall & cmake $*"
    else
        cmake "$@"
    fi
}

cd "$BUILD_DIR"
echo "Calling cmake with the following options:"
echo "$cmake_options" | tr -s ' ' '\n'
if [ -e "full-build" ]; then
    call-cmake -G"$(generator)" $cmake_options "$SRC_DIR"
else
    call-cmake $cmake_options .
fi
