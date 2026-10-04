#!/bin/bash
set -euo pipefail
# Existing IPA job only. Fixtures and executable live in runner temp, not IPA.
command -v ffmpeg >/dev/null || brew install ffmpeg
MEDIA="$RUNNER_TEMP/cineva-preview-media"
mkdir -p "$MEDIA"
python3 Tests/PlayerTransport/preview_frames.py "$MEDIA/frames"
ffmpeg -hide_banner -loglevel error -y -framerate 24 -i "$MEDIA/frames/%03d.ppm" \
  -f lavfi -i 'sine=frequency=440:duration=6' -c:v libx264 -pix_fmt yuv420p -g 120 -bf 3 -c:a aac \
  -movflags +faststart "$MEDIA/bframes.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -c copy "$MEDIA/longgop.mkv"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -c:v libx265 -x265-params log-level=error \
  -tag:v hvc1 -c:a copy "$MEDIA/hevc.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -r 24000/1001 -c:v libx264 -c:a copy "$MEDIA/fractional.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -vf "select='if(lt(t,3),1,not(mod(n,2)))'" \
  -fps_mode vfr -c:v libx264 -c:a copy "$MEDIA/vfr.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -an -c:v copy "$MEDIA/noaudio.mp4"
ffmpeg -hide_banner -loglevel error -y -display_rotation:v:0 90 -i "$MEDIA/bframes.mp4" -c copy "$MEDIA/rotated.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -c copy -output_ts_offset 2 "$MEDIA/origin.mp4"
printf '1\n00:00:01,000 --> 00:00:05,000\nFixture subtitles\n' > "$MEDIA/text.srt"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -i "$MEDIA/text.srt" -map 0 -map 1 -c copy -c:s srt "$MEDIA/subtitles.mkv"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -c copy \
  -movflags +frag_keyframe+empty_moov+default_base_moof "$MEDIA/fragmented.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -c copy -tag:v avc3 "$MEDIA/avc3.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -c:v copy -c:a eac3 "$MEDIA/eac3.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/bframes.mp4" -i "$MEDIA/text.srt" -map 0 -map 1 \
  -c copy -c:s mov_text "$MEDIA/subtitles.mp4"
# VUI marks PQ while the remux deliberately leaves container colr unspecified.
# Verify first decoded metadata; this does not verify a physical HDR display.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=24:duration=6' \
  -f lavfi -i 'sine=frequency=440:duration=6' -c:v libx265 -pix_fmt yuv420p10le \
  -x265-params log-level=error -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -tag:v hvc1 -c:a aac "$MEDIA/hdr-vui.mp4"
ffmpeg -hide_banner -loglevel error -y -i "$MEDIA/hdr-vui.mp4" -c copy -color_primaries unknown \
  -color_trc unknown -colorspace unknown -movflags +faststart "$MEDIA/hdr-no-colr.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'color=c=blue:size=3840x2160:rate=24:duration=6' \
  -f lavfi -i 'sine=frequency=440:duration=6' -c:v libx264 -preset ultrafast -g 24 -c:a aac "$MEDIA/4k.mp4"
# A real eleven-minute indexed A/V container over 512 MiB, not padded random bytes.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc2=size=320x180:rate=24' \
  -f lavfi -i 'sine=frequency=440' -t 660 -c:v libx264 -preset ultrafast -g 120 \
  -b:v 7M -minrate 7M -maxrate 7M -bufsize 14M -x264-params nal-hrd=cbr:force-cfr=1 \
  -c:a aac -movflags +faststart "$MEDIA/long-cache.mp4"
ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation -of json "$MEDIA/rotated.mp4" | \
  python3 -c 'import json,sys; j=json.load(sys.stdin); assert any(abs(x.get("rotation",0))==90 for s in j["streams"] for x in s.get("side_data_list",[])), "Fixture has no rotation matrix"; print("Fixture rotation matrix verified")'
python3 Tests/PlayerTransport/range_server.py --port-file "$RUNNER_TEMP/preview-port" --media-dir "$MEDIA" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for attempt in {1..100}; do test -s "$RUNNER_TEMP/preview-port" && break; sleep 0.1; done
SIM_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for v in json.load(sys.stdin)["devices"].values() for d in v if d["isAvailable"] and "iPhone" in d["name"]))')
xcrun simctl boot "$SIM_ID" || true
xcrun simctl bootstatus "$SIM_ID" -b
FRAMEWORK_DIR="$PWD/Dependencies/FFmpeg/Generated/CinevaFFmpeg.xcframework/ios-arm64-simulator"
# Compile the actual shared display controller without unrelated player views.
# This generated runner-temp slice is never copied into application sources.
python3 - "$RUNNER_TEMP/PreviewDisplay.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Gallery115/Player/SystemPlayerView.swift').read_text()
start = source.index('@MainActor\n@Observable\nfinal class TimelinePreviewController')
end = source.index('struct TimelinePreviewOverlay:', start)
Path(sys.argv[1]).write_text('import AVFoundation\nimport UIKit\nimport CoreImage\nimport Observation\n' + source[start:end])
PY
xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -D PREVIEW_WORKER_TEST \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Gallery115/Info.plist \
  -F "$FRAMEWORK_DIR" -framework CinevaFFmpeg -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
  Gallery115/Models/VideoSource.swift Gallery115/PlayerCore/RangeCoordinator.swift \
  Gallery115/PlayerCore/FFmpegIOBridge.swift Gallery115/PlayerCore/FFmpegSessionHandle.swift \
  Gallery115/PlayerCore/PlaybackPolicy.swift "$RUNNER_TEMP/PreviewDisplay.swift" \
  Gallery115/PlayerCore/FFmpegTimelinePreview.swift Tests/PlayerTransport/PreviewChecks.swift \
  -o "$RUNNER_TEMP/preview-checks"
codesign --force --sign - "$RUNNER_TEMP/preview-checks"
# AAC encoder priming can place the container origin before the first video
# frame. The burned-in frame number is relative to VIDEO start, not audio start.
VIDEO_OFFSET=$(ffprobe -v error -show_entries format=start_time:stream=codec_type,start_time -of json "$MEDIA/origin.mp4" | \
  python3 -c 'import json,sys; j=json.load(sys.stdin); print(float(next(s["start_time"] for s in j["streams"] if s["codec_type"]=="video"))-float(j["format"]["start_time"]))')
xcrun simctl spawn "$SIM_ID" "$RUNNER_TEMP/preview-checks" "http://127.0.0.1:$(cat "$RUNNER_TEMP/preview-port")" "$VIDEO_OFFSET"
