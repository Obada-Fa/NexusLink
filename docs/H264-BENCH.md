# H.264 stream benchmark

## Phase 1 — MJPEG baseline, 2026-11-11

Linux X11 loopback on the RX 9070 XT host. Bun 1.3.14, FFmpeg 6.1.1, GStreamer 1.24.2 and headless Google Chrome 157. One run per row. The existing capture handler used its 24 fps medium preset (JPEG quality 5, 960 px maximum width for physical captures, native size for virtual sessions). The benchmark sent no phone QoS reports, so the starting preset stayed fixed.

| Target | Scene | Capture → delivered pixels | kbit/s | Delivered fps | Tap median (ms) | Tap max (ms) |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Virtual | Static | 720×1280 → 720×1280 | 45,877 | 24.0 | 109.7 | 133.4 |
| Virtual | Scrolling | 720×1280 → 720×1280 | 45,772 | 24.0 | 109.6 | 129.8 |
| Window crop | Static | 1100×850 → 960×742 | 44,454 | 24.0 | 109.4 | 130.1 |
| Window crop | Scrolling | 1100×850 → 960×742 | 43,332 | 24.0 | 109.6 | 129.0 |
| Desktop | Static | 1920×1080 → 960×540 | 36,932 | 24.0 | 110.2 | 129.7 |
| Desktop | Scrolling | 1920×1080 → 960×540 | 36,692 | 24.0 | 108.0 | 124.9 |

### Reproduce the baseline

From the repository root with Bun, Xvfb, xauth, xrandr, xdotool, FFmpeg, Python with Tk, and Chrome or Chromium on the path.

```sh
python3 scripts/stream-bench/run.py
python3 scripts/stream-bench/run.py --target window --scene scrolling --chrome chromium
```

Each run starts an authenticated private Xvfb, a Tk test app, a loopback-only Bun server on an ephemeral port, and headless Chrome with a scratch profile. The test app toggles a red/green marker on a click. Its text is either stationary or scrolls at 95 px/s. The Bun server calls the production capture and X11 click handlers. Chrome warms up for one second after the first decoded picture and samples for ten seconds. Each row includes ten taps at varied intervals. The runner prints JSON lines with the individual delays, elapsed time, and delivered dimensions.

- **Bitrate** counts binary WebSocket message bytes, including the 16-byte NexusLink header. WebSocket, TCP and IP overhead are outside this measurement.
- **Delivered fps** counts JPEGs decoded and drawn to the browser canvas.
- **Tap-to-picture** starts on the browser clock immediately before sending the tap over the WebSocket. It ends when the browser first draws a decoded frame with the changed marker. It includes local transport and X11 injection. Browser compositing and physical screen refresh are outside this measurement.

### VA-API proof

PCI `0000:03:00.0` (AMD `1002:7550`, `amdgpu`) is the RX 9070 XT. Its stable render path `/dev/dri/by-path/pci-0000:03:00.0-render` resolved to `/dev/dri/renderD128` during this run. The other render node belonged to the Raphael iGPU at `0000:0d:00.0`.

The system exposes the legacy GStreamer `vaapih264enc` element. Its keyframe property is `keyframe-period`. The picker previously used `key-int-max` for both VA-API elements. The fix preserves `key-int-max` for `vah264enc` and uses `keyframe-period` for `vaapih264enc`.

A GStreamer probe with the legacy element encoded 48 frames of 720×1280 constrained-baseline H.264 at a 24 fps input rate. `strace` showed a successful open of the PCI-specific render path and `radeonsi_drv_video.so`. The libva trace recorded `VAProfileH264ConstrainedBaseline`, `VAEntrypointEncSlice`, and 48 completed picture submissions. The pipeline contained a single encoder, `vaapih264enc`.

To repeat that encoder-only probe, with `scratch` set to a writable scratch directory:

```sh
env -u DISPLAY -u WAYLAND_DISPLAY \
  HOME="$scratch" XDG_CACHE_HOME="$scratch/cache" \
  GST_VAAPI_DRM_DEVICE=/dev/dri/by-path/pci-0000:03:00.0-render \
  LIBVA_TRACE="$scratch/libva" \
  strace -f -e openat -o "$scratch/open.log" \
  gst-launch-1.0 -q videotestsrc num-buffers=48 \
  ! video/x-raw,format=NV12,width=720,height=1280,framerate=24/1 \
  ! vaapih264enc bitrate=4000 keyframe-period=48 max-bframes=0 rate-control=cbr \
  ! video/x-h264,profile=constrained-baseline ! fakesink
```

Unsetting `DISPLAY` and `WAYLAND_DISPLAY` selects the DRM backend for this probe. Host integration of PCI-based selection is Phase 2.

The corrected production agent also captured a private 720×1280 Xvfb through its explicit `--display` argument and emitted an H.264 offer (`profile-level-id=42c01f`) and ICE candidates. The only DRM device it opened was `renderD128`. The kernel reported `drm-pdev: 0000:03:00.0` and 6,503,354 ns on `drm-engine-enc` while preparing the offer, with five completed pictures in the libva trace. This check stopped at signaling, before a receiver answered the offer.

The host's system plugin set lacks `webrtcbin`, `h264parse`, and `nicesrc`. The agent smoke test used the matching Ubuntu `gstreamer1.0-plugins-bad`, `gstreamer1.0-nice`, and `libsrtp2-1` packages extracted into scratch space via `dpkg-deb -x`. The agent received a private `GST_PLUGIN_PATH` (video parsers, WebRTC, Nice, DTLS and SRTP) and `LD_LIBRARY_PATH`. This required no system installation.

### Still to verify

- End-to-end H.264 delivery and its bitrate, fps and tap-to-picture delay. The before/after table belongs to Phase 4.
- Capture of the owner's real desktop at its actual resolution.
- The phone's H.264 decoder, including portrait profile and level compatibility, and performance on mobile data.
