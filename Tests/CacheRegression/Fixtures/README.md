# Near-start extraction fixture

`near-start.mp4` is synthetic gray video, 64×64, H.264/yuv420p, 30 frames, one second, with a front-loaded MP4 index. It contains no user media or audio.

Recreate with:

```sh
ffmpeg -f lavfi -i 'color=c=0xb4b4b4:s=64x64:r=30:d=1' -c:v libx264 -pix_fmt yuv420p -movflags +faststart near-start.mp4
```

The XCTest runs the production AVAssetImageGenerator extraction path against this file. Encoding is intentionally performed ahead of time to avoid unrelated AVAssetWriter readiness failures on shared simulators.
