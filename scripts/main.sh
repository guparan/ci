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

    if [ ! -d "$1" ]; then
        mkdir -p "$1";
    fi
    
    BUILD_DIR="$(cd "$1" && pwd)"
    BUILD_DIR_RESET="$BUILD_DIR"
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

# Jenkins: create link for Windows jobs (too long path problem)
if vm-is-windows && [ -n "$EXECUTOR_NUMBER" ]; then
    export BUILD_DIR_WINDOWS="$(cd "$BUILD_DIR" && pwd -W | sed 's#/#\\#g')"
    cmd //c "mklink /D j:\build%EXECUTOR_NUMBER% %BUILD_DIR_WINDOWS%"
    BUILD_DIR="/j/build$EXECUTOR_NUMBER"
fi

cd "$SRC_DIR"
echo "main.sh: pwd = $(pwd)"
echo "main.sh: BUILD_DIR = $BUILD_DIR"

# Jenkins: clean Warnings parser links
if [ -n "$WORKSPACE" ]; then
    if vm-is-windows; then
        export WORKSPACE_WINDOWS="$(cd "$WORKSPACE" && pwd -W | sed 's#/#\\#g')"
        cmd //c "if exist %WORKSPACE_WINDOWS%\parent rmdir %WORKSPACE_WINDOWS%\parent"
    else
        rm -f "parent"
    fi
fi

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
rm -rf "$BUILD_DIR/bin"
rm -rf "$BUILD_DIR/lib"



# CI environment variables + init
github-export-vars "$PLATFORM" "$COMPILER" "$ARCHITECTURE" "$BUILD_TYPE" "$BUILD_OPTIONS"
dashboard-export-vars "$PLATFORM" "$COMPILER" "$ARCHITECTURE" "$BUILD_TYPE" "$BUILD_OPTIONS"

github-notify "pending" "Building..."
dashboard-notify "status=build"


# VM environment variables
echo "ENV VARS: load $SCRIPT_DIR/env/default"
. "$SCRIPT_DIR/env/default"
if [ -n "$NODE_NAME" ]; then
    if [ -e "$SCRIPT_DIR/env/$NODE_NAME" ]; then
        echo "ENV VARS: load node specific $SCRIPT_DIR/env/$NODE_NAME"
        . "$SCRIPT_DIR/env/$NODE_NAME"
    else
        echo "ERROR: No config file found for node $NODE_NAME."
        exit 1
    fi
fi


# Configure
. "$SCRIPT_DIR/configure.sh" "$BUILD_DIR" "$SRC_DIR" "$COMPILER" "$ARCHITECTURE" "$BUILD_TYPE" "$BUILD_OPTIONS"


# Compile
"$SCRIPT_DIR/compile.sh" "$BUILD_DIR" "$COMPILER" "$ARCHITECTURE"
dashboard-notify "status=success"
github_status="success"
github_message="Build OK"
github-notify "$github_status" "$github_message"

# [Full build] Count Warnings
if in-array "force-full-build" "$BUILD_OPTIONS"; then
    if vm-is-windows; then
        warning_count=$(grep 'warning [A-Z]\+[0-9]\+:' "$BUILD_DIR/make-output.txt" | sort | uniq | wc -l)
    else
        warning_count=$(grep '^[^:]\+:[0-9]\+:[0-9]\+: warning:' "$BUILD_DIR/make-output.txt" | sort -u | wc -l | tr -d ' ')
    fi
    echo "Counted $warning_count compiler warnings."
    dashboard-notify "warnings=$warning_count"
fi

# Reset BUILD_DIR for tests (Windows too long path problem)
BUILD_DIR="$BUILD_DIR_RESET"

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

    tests_problems=$((tests_failures+tests_errors))
    github_message="${github_message}, $tests_problems unit-test problems"
    if [ $tests_problems -gt 0 ]; then
        github_status="success" # do not fail on tests failure
    fi

    dashboard-notify \
        "tests_status=success" \
        "tests_suites=$tests_suites" \
        "tests_total=$tests_total" \
        "tests_disabled=$tests_disabled" \
        "tests_failures=$tests_failures" \
        "tests_errors=$tests_errors"
fi

# Scene tests
if in-array "run-scene-tests" "$BUILD_OPTIONS"; then
    dashboard-notify "scenes_status=running"
    
    echo "Preventing SofaCUDA from being loaded in VMs."
    if vm-is-windows; then
        plugin_conf="$BUILD_DIR/bin/plugin_list.conf.default"
    else
        plugin_conf="$BUILD_DIR/lib/plugin_list.conf.default"
    fi
    grep -v "SofaCUDA NO_VERSION" "$plugin_conf" > "${plugin_conf}.tmp" && mv "${plugin_conf}.tmp" "$plugin_conf"

    "$SCRIPT_DIR/scene-tests.sh" run "$BUILD_DIR" "$SRC_DIR"
    "$SCRIPT_DIR/scene-tests.sh" print-summary "$BUILD_DIR" "$SRC_DIR"

    scenes_total=$("$SCRIPT_DIR/scene-tests.sh" count-tests $BUILD_DIR $SRC_DIR)
    scenes_successes=$("$SCRIPT_DIR/scene-tests.sh" count-successes $BUILD_DIR $SRC_DIR)
    scenes_errors=$("$SCRIPT_DIR/scene-tests.sh" count-errors $BUILD_DIR $SRC_DIR)
    scenes_crashes=$("$SCRIPT_DIR/scene-tests.sh" count-crashes $BUILD_DIR $SRC_DIR)

    scenes_problems=$((scenes_errors+scenes_crashes))
    github_message="${github_message}, $scenes_problems scene-test problems"
    if [ $scenes_problems -gt 0 ]; then
        github_status="success" # do not fail on tests failure
    fi
    
    dashboard-notify \
        "scenes_status=success" \
        "scenes_total=$scenes_total" \
        "scenes_successes=$scenes_successes" \
        "scenes_errors=$scenes_errors" \
        "scenes_crashes=$scenes_crashes"

    # Clamping warning file to avoid Jenkins overflow
    "$SCRIPT_DIR/scene-tests.sh" clamp-warnings "$BUILD_DIR" "$SRC_DIR" 5000
fi

# Update GitHub message with test results
github-notify "$github_status" "$github_message"

if in-array "force-full-build" "$BUILD_OPTIONS"; then
    mv "$BUILD_DIR/make-output.txt" "$BUILD_DIR/make-output-fullbuild-$COMPILER.txt"
fi
