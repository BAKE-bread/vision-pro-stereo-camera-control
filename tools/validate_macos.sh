#!/bin/bash
# Run from any directory. Existing results and source files are never deleted.
set -euo pipefail
cd "$(dirname "$0")/.."

python_path="${STEREO_PYTHON:-.venv-macos/bin/python}"
scheme=StereoStudio
if [[ "${1:-}" == "--local" ]]; then
    scheme=StereoStudioLocal
elif [[ -n "${1:-}" ]]; then
    echo "Usage: bash tools/validate_macos.sh [--local]" >&2
    exit 2
fi
if [[ ! -x "$python_path" ]]; then
    echo "Create .venv-macos and install dependencies first; see docs/RUNBOOK.md." >&2
    exit 1
fi

result_dir="artifacts/validation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$result_dir"
"$python_path" -m pytest -q | tee "$result_dir/pytest.log"
"$python_path" tools/check_apple_sources.py | tee "$result_dir/source-check.log"

xcodebuild -project apple/StereoStudio.xcodeproj -scheme "$scheme" \
    -destination "${STEREO_TEST_DESTINATION:-platform=visionOS Simulator,name=Apple Vision Pro}" \
    -derivedDataPath artifacts/DerivedData -clonedSourcePackagesDirPath artifacts/SourcePackages \
    -resultBundlePath "$result_dir/Tests.xcresult" CODE_SIGNING_ALLOWED=NO test \
    > "$result_dir/xcode-tests.log" 2>&1
xcodebuild -project apple/StereoStudio.xcodeproj -scheme StereoStudio \
    -destination 'generic/platform=visionOS' -derivedDataPath artifacts/DerivedData \
    -clonedSourcePackagesDirPath artifacts/SourcePackages CODE_SIGNING_ALLOWED=NO build \
    > "$result_dir/xcode-device.log" 2>&1
echo "Validation passed. Logs: $result_dir"
