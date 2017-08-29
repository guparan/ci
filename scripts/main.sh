#!/bin/bash
set -o errexit # Exit on error

usage() {
    echo "Usage: main.sh <build-dir> <src-dir> <platform> <compiler> <architecture> <build-type> <build-options>"
}

if [ "$#" -ge 6 ]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    . "$SCRIPT_DIR"/utils.sh
    . "$SCRIPT_DIR"/dashboard.sh
    . "$SCRIPT_DIR"/github.sh

    if [[ ! -d "$1" ]]; then mkdir -p "$1"; fi
    BUILD_DIR="$(cd "$1" && pwd)"
    SRC_DIR="$(cd "$2" && pwd)"

    PLATFORM="$3"
    COMPILER="$4"
    ARCHITECTURE="$5"
    BUILD_TYPE="$6"
    BUILD_OPTIONS="${*:7}"
    if [ -z "$BUILD_OPTIONS" ]; then
        BUILD_OPTIONS="$(get-build-options)" # use env vars (Jenkins)
    fi
else
    usage; exit 1
fi

cd "$SRC_DIR"


# Check [ci-ignore] flag in commit message
commit_message_full="$(git log --pretty=%B -1)"
if [[ "$commit_message_full" == *"[ci-ignore]"* ]]; then
    # Ignore this build
    echo "WARNING: [ci-ignore] detected in commit message, build aborted."
    exit
fi

# Clean build dir
rm -f "$BUILD_DIR/make-output*.txt"
rm -rf "$BUILD_DIR/unit-tests/reports"
rm -rf "$BUILD_DIR/scene-tests/reports"
# rm -rf "$BUILD_DIR/bin"
# rm -rf "$BUILD_DIR/lib"


# CI environment variables + init
github-export-vars "$PLATFORM" "$COMPILER" "$ARCHITECTURE" "$BUILD_TYPE" "$BUILD_OPTIONS"
dashboard-export-vars "$PLATFORM" "$COMPILER" "$ARCHITECTURE" "$BUILD_TYPE" "$BUILD_OPTIONS"

github-notify "pending" "Build started."
dashboard-notify "status=build"


# VM environment variables
if vm-is-windows && [ -e "$SCRIPT_DIR/env/default-windows" ]; then
    echo "ENV VARS: load $SCRIPT_DIR/env/default-windows"
    . "$SCRIPT_DIR/env/default-windows"
elif vm-is-macos && [ -e "$SCRIPT_DIR/env/default-macos" ]; then
    echo "ENV VARS: load $SCRIPT_DIR/env/default-macos"
    . "$SCRIPT_DIR/env/default-macos"
elif vm-is-centos && [ -e "$SCRIPT_DIR/env/default-centos" ]; then
    echo "ENV VARS: load $SCRIPT_DIR/env/default-centos"
    . "$SCRIPT_DIR/env/default-centos"
elif [ -e "$SCRIPT_DIR/env/default-unix" ]; then
    echo "ENV VARS: load $SCRIPT_DIR/env/default-unix"
    . "$SCRIPT_DIR/env/default-unix"
fi
if [ -n "$NODE_NAME" ] && [ -e "$SCRIPT_DIR/env/$NODE_NAME" ]; then
    echo "ENV VARS: load node specific $SCRIPT_DIR/env/$NODE_NAME"
    . "$SCRIPT_DIR/env/$NODE_NAME"
fi


# Configure
"$SCRIPT_DIR/configure.sh" "$BUILD_DIR" "$SRC_DIR" "$COMPILER" "$ARCHITECTURE" "$BUILD_TYPE" "$BUILD_OPTIONS"


# Compile
"$SCRIPT_DIR/compile.sh" "$BUILD_DIR" "$COMPILER" "$ARCHITECTURE"
dashboard-notify "status=success"
github-notify "success" "SUCCESS (tests ignored)"

# [Full build] Count Warnings
if in-array "force-full-build" "$BUILD_OPTIONS"; then
    if vm-is-windows; then
        warning_count=$(grep ' : warning [A-Z]\+[0-9]\+:' "$BUILD_DIR/make-output.txt" | sort | uniq | wc -l)
    else
        warning_count=$(grep '^[^:]\+:[0-9]\+:[0-9]\+: warning:' "$BUILD_DIR/make-output.txt" | sort -u | wc -l | tr -d ' ')
    fi
    echo "Counted $warning_count compiler warnings."
    dashboard-notify "warnings=$warning_count"
fi

# Unit tests
if in-array "run-unit-tests" "$BUILD_OPTIONS"; then
    dashboard-notify "tests_status=running"

    "$SCRIPT_DIR/unit-tests.sh" run "$BUILD_DIR" "$SRC_DIR"
    "$SCRIPT_DIR/unit-tests.sh" print-summary "$BUILD_DIR" "$SRC_DIR"

    tests_suites=$("$SCRIPT_DIR/unit-tests.sh" count-test-suites $BUILD_DIR $SRC_DIR)
    tests_total=$("$SCRIPT_DIR/unit-tests.sh" count-tests $BUILD_DIR $SRC_DIR)
    tests_disabled=$("$SCRIPT_DIR/unit-tests.sh" count-disabled $BUILD_DIR $SRC_DIR)
    tests_failures=$("$SCRIPT_DIR/unit-tests.sh" count-failures $BUILD_DIR $SRC_DIR)
    tests_errors=$("$SCRIPT_DIR/unit-tests.sh" count-errors $BUILD_DIR $SRC_DIR)

    dashboard-notify \
        "tests_suites=$tests_suites" \
        "tests_total=$tests_total" \
        "tests_disabled=$tests_disabled" \
        "tests_failures=$tests_failures" \
        "tests_errors=$tests_errors"
fi

# Scene tests
if in-array "run-scene-tests" "$BUILD_OPTIONS"; then
    dashboard-notify "scenes_status=running"

    "$SCRIPT_DIR/scene-tests.sh" run "$BUILD_DIR" "$SRC_DIR"
    "$SCRIPT_DIR/scene-tests.sh" print-summary "$BUILD_DIR" "$SRC_DIR"

    scenes_total=$("$SCRIPT_DIR/scene-tests.sh" count-tests $BUILD_DIR $SRC_DIR)
    scenes_errors=$("$SCRIPT_DIR/scene-tests.sh" count-errors $BUILD_DIR $SRC_DIR)
    scenes_crashes=$("$SCRIPT_DIR/scene-tests.sh" count-crashes $BUILD_DIR $SRC_DIR)

    dashboard-notify \
        "scenes_total=$scenes_total" \
        "scenes_errors=$scenes_errors" \
        "scenes_crashes=$scenes_crashes"
fi

if in-array "force-full-build" "$BUILD_OPTIONS"; then
    mv "$BUILD_DIR/make-output.txt" "$BUILD_DIR/make-output-$COMPILER.txt"
fi
