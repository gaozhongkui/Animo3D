#!/bin/bash
set -euo pipefail

repository_dir="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="$(xcode-select -p)"
test_frameworks="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
test_libraries="$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib"
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/animo-user-content-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT

xcrun swiftc \
    -module-cache-path "$test_build_dir/modules" \
    -F "$test_frameworks" \
    -I "$test_libraries" \
    -L "$test_libraries" \
    -Xlinker -rpath \
    -Xlinker "$test_frameworks" \
    -Xlinker -rpath \
    -Xlinker "$test_libraries" \
    "$repository_dir/Animo3D/Core/Assets/UserContentStorage.swift" \
    "$repository_dir/tools/tests/UserContentStorageTests.swift" \
    -o "$test_build_dir/user-content-tests"

"$test_build_dir/user-content-tests"
