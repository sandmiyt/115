#!/bin/bash
set -euo pipefail
# Existing IPA job only. Fixtures and executable live in runner temp, not IPA.
command -v ffmpeg >/dev/null || brew install ffmpeg
MEDIA="$RUNNER_TEMP/cineva-preview-media"
mkdir -p "$MEDIA"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=6' \
  -f lavfi -i 'sine=frequency=440:duration=6' -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='%{n}':x=10:y=10:fontsize=24:fontcolor=white" -c:v libx264 -g 120 -bf 3 -c:a aac \
  -movflags +faststart "$MEDIA/bframes.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -c copy "$MEDIA/longgop.mkv"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -c:v libx265 -x265-params log-level=error \
  -tag:v hvc1 -c:a copy "$MEDIA/hevc.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -r 24000/1001 -c:v libx264 -c:a copy "$MEDIA/fractional.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -vf "select='if(lt(t,3),1,not(mod(n,2)))'" \
  -fps_mode vfr -c:v libx264 -c:a copy "$MEDIA/vfr.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -an -c:v copy "$MEDIA/noaudio.mp4"
python3 Tests/PlayerTransport/range_server.py --port-file "$RUNNER_TEMP/preview-port" --media-dir "$MEDIA" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for attempt in {1..100}; do test -s "$RUNNER_TEMP/preview-port" && break; sleep 0.1; done
SIM_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for v in json.load(sys.stdin)["devices"].values() for d in v if d["isAvailable"] and "iPhone" in d["name"]))')
xcrun simctl boot "$SIM_ID" || true
xcrun simctl bootstatus "$SIM_ID" -b
FRAMEWORK_DIR="$PWD/Dependencies/FFmpeg/Generated/CinevaFFmpeg.xcframework/ios-arm64-simulator"
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -D PREVIEW_WORKER_TEST \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Gallery115/Info.plist \
  -F "$FRAMEWORK_DIR" -framework CinevaFFmpeg -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
  Gallery115/Models/VideoSource.swift Gallery115/PlayerCore/RangeCoordinator.swift \
  Gallery115/PlayerCore/FFmpegIOBridge.swift Gallery115/PlayerCore/FFmpegSessionHandle.swift \
  Gallery115/PlayerCore/FFmpegTimelinePreview.swift Tests/PlayerTransport/PreviewChecks.swift \
  -o "$RUNNER_TEMP/preview-checks"
codesign --force --sign - "$RUNNER_TEMP/preview-checks"
xcrun simctl spawn "$SIM_ID" "$RUNNER_TEMP/preview-checks" "http://127.0.0.1:$(cat "$RUNNER_TEMP/preview-port")"
