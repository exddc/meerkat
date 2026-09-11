#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/generate-metrics.sh [options]

Options:
  --duration <Ns|Nm|Nh>  Recording duration (default: 5m)
  --warmup <Ns|Nm|Nh>    Initial time excluded from aggregates (default: 30s)
  --label <text>          Scenario label stored in summary.json (default: unlabeled)
  --output-dir <path>     Output directory (default: metrics/<UTC timestamp>)
  --attach <pid|name>     Attach to a running process instead of building and launching
  --help                  Show this help
EOF
}

duration_seconds() {
    local value="$1"
    local amount="${value%?}"
    local unit="${value: -1}"

    if ! [[ "$value" =~ ^[0-9]+[smh]$ ]]; then
        echo "error: duration must use an integer followed by s, m, or h: $value" >&2
        return 1
    fi
    amount=$((10#$amount))

    case "$unit" in
        s) echo "$amount" ;;
        m) echo $((amount * 60)) ;;
        h) echo $((amount * 3600)) ;;
    esac
}

attach_pid() {
    local target="$1"
    local matches=""
    local match=""
    local count=0

    if [[ "$target" =~ ^[0-9]+$ ]]; then
        if ! ps -p "$target" -o pid= >/dev/null 2>&1; then
            echo "error: no running process has PID $target" >&2
            return 1
        fi
        ps -p "$target" -o pid= | tr -d ' '
        return
    fi
    if [[ "$target" == -* ]]; then
        echo "error: process name cannot start with a dash: $target" >&2
        return 1
    fi

    matches="$(pgrep -x "$target" || true)"
    while IFS= read -r match; do
        [[ -n "$match" ]] || continue
        count=$((count + 1))
    done <<< "$matches"

    if [[ "$count" -eq 0 ]]; then
        echo "error: no running process named $target" >&2
        return 1
    fi
    if [[ "$count" -gt 1 ]]; then
        echo "error: multiple processes are named $target; attach by PID" >&2
        return 1
    fi
    echo "$matches"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DURATION="5m"
WARMUP="30s"
LABEL="unlabeled"
OUTPUT_DIR=""
ATTACH_TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            [[ $# -ge 2 ]] || { echo "error: --duration requires a value" >&2; exit 2; }
            DURATION="$2"
            shift 2
            ;;
        --warmup)
            [[ $# -ge 2 ]] || { echo "error: --warmup requires a value" >&2; exit 2; }
            WARMUP="$2"
            shift 2
            ;;
        --label)
            [[ $# -ge 2 ]] || { echo "error: --label requires a value" >&2; exit 2; }
            LABEL="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "error: --output-dir requires a value" >&2; exit 2; }
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --attach)
            [[ $# -ge 2 ]] || { echo "error: --attach requires a PID or process name" >&2; exit 2; }
            ATTACH_TARGET="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

DURATION_SECONDS="$(duration_seconds "$DURATION")"
WARMUP_SECONDS="$(duration_seconds "$WARMUP")"
if [[ "$DURATION_SECONDS" -eq 0 ]]; then
    echo "error: duration must be greater than zero" >&2
    exit 2
fi
if [[ "$WARMUP_SECONDS" -ge "$DURATION_SECONDS" ]]; then
    echo "error: warmup must be shorter than duration" >&2
    exit 2
fi
if [[ -z "$ATTACH_TARGET" ]] && pgrep -x Meerkat >/dev/null 2>&1; then
    echo "error: Meerkat is already running; quit it or use --attach Meerkat" >&2
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$PROJECT_ROOT/metrics/$(date -u +%Y%m%d-%H%M%S)"
elif [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$PROJECT_ROOT/$OUTPUT_DIR"
fi

if [[ -e "$OUTPUT_DIR" ]]; then
    echo "error: output directory already exists: $OUTPUT_DIR" >&2
    exit 2
fi
mkdir -p "$OUTPUT_DIR"

command -v xcodebuild >/dev/null || { echo "error: xcodebuild is required" >&2; exit 1; }
xcrun --find xctrace >/dev/null
xcrun --find swift >/dev/null

GIT_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]]; then
    GIT_DIRTY="true"
else
    GIT_DIRTY="false"
fi
MACOS_VERSION="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
HARDWARE_MODEL="$(sysctl -n hw.model)"
PROCESSOR="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
if [[ -n "$PROCESSOR" ]]; then
    HARDWARE_MODEL="$HARDWARE_MODEL, $PROCESSOR"
fi
XCODE_VERSION="$(xcodebuild -version | paste -sd ' ' -)"

TRACE_PATH="$OUTPUT_DIR/activity.trace"
PROCESS_XML="$OUTPUT_DIR/process.xml"
THERMAL_XML="$OUTPUT_DIR/thermal.xml"
SAMPLES_CSV="$OUTPUT_DIR/samples.csv"
SUMMARY_JSON="$OUTPUT_DIR/summary.json"
BUILD_LOG="$OUTPUT_DIR/build.log"
XCTRACE_LOG="$OUTPUT_DIR/xctrace.log"

cd "$PROJECT_ROOT"

if [[ -n "$ATTACH_TARGET" ]]; then
    MODE="attach"
    PROFILE_TARGET="$(attach_pid "$ATTACH_TARGET")"
    ATTACHED_COMMAND="$(ps -ww -p "$PROFILE_TARGET" -o command= | sed 's/^[[:space:]]*//')"
    APP_DESCRIPTION="attached:$PROFILE_TARGET:$ATTACHED_COMMAND"
else
    MODE="launch"
    DERIVED_DATA="${MEERKAT_METRICS_DERIVED_DATA:-$PROJECT_ROOT/.build/metrics-derived-data}"
    PACKAGE_CACHE="${MEERKAT_METRICS_PACKAGE_CACHE:-$PROJECT_ROOT/.build}"
    echo "Building Meerkat (Release)..."
    if ! xcodebuild \
        -project Meerkat.xcodeproj \
        -scheme Meerkat \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
        build >"$BUILD_LOG" 2>&1; then
        tail -40 "$BUILD_LOG" >&2
        exit 1
    fi

    APP_EXECUTABLE="$DERIVED_DATA/Build/Products/Release/Meerkat.app/Contents/MacOS/Meerkat"
    if [[ ! -x "$APP_EXECUTABLE" ]]; then
        echo "error: built app executable not found: $APP_EXECUTABLE" >&2
        exit 1
    fi
    PROFILE_TARGET="$APP_EXECUTABLE"
    APP_DESCRIPTION="$APP_EXECUTABLE"
fi

echo "Recording $LABEL for $DURATION..."
if [[ "$MODE" == "attach" ]]; then
    xcrun xctrace record \
        --template "Activity Monitor" \
        --time-limit "$DURATION" \
        --output "$TRACE_PATH" \
        --no-prompt \
        --attach "$PROFILE_TARGET" >"$XCTRACE_LOG" 2>&1
else
    xcrun xctrace record \
        --template "Activity Monitor" \
        --time-limit "$DURATION" \
        --output "$TRACE_PATH" \
        --no-prompt \
        --launch -- "$PROFILE_TARGET" >"$XCTRACE_LOG" 2>&1
fi

echo "Exporting trace tables..."
xcrun xctrace export \
    --input "$TRACE_PATH" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]' \
    --output "$PROCESS_XML"
xcrun xctrace export \
    --input "$TRACE_PATH" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="device-thermal-state-intervals"]' \
    --output "$THERMAL_XML"

echo "Summarizing samples..."
xcrun swift "$SCRIPT_DIR/summarize-metrics.swift" \
    --process "$PROCESS_XML" \
    --thermal "$THERMAL_XML" \
    --csv "$SAMPLES_CSV" \
    --summary "$SUMMARY_JSON" \
    --label "$LABEL" \
    --mode "$MODE" \
    --target "$APP_DESCRIPTION" \
    --duration "$DURATION_SECONDS" \
    --warmup "$WARMUP_SECONDS" \
    --commit "$GIT_COMMIT" \
    --dirty "$GIT_DIRTY" \
    --macos "$MACOS_VERSION" \
    --hardware "$HARDWARE_MODEL" \
    --xcode "$XCODE_VERSION"

echo "Raw trace: $TRACE_PATH"
echo "Summary:   $SUMMARY_JSON"
echo "Samples:   $SAMPLES_CSV"
