#!/usr/bin/env python3
"""NexusLink WebRTC encoder agent.

One process per stream: captures a region of an X display with ximagesrc,
encodes H.264 with VA-API plus optional Opus from a PulseAudio monitor, and
negotiates a WebRTC session through GStreamer's webrtcbin.

Signaling rides on stdio as JSON lines; the Bun host relays them verbatim to
the phone over the paired control WebSocket:

  stdout -> {"type": "offer", "sdp": ...}
            {"type": "ice", "candidate": ..., "sdpMLineIndex": ...}
            {"type": "status", "state": ...} / {"type": "error", "message": ...}
  stdin  <- {"type": "answer", "sdp": ...}
            {"type": "ice", "candidate": ..., "sdpMLineIndex": ...}
            {"type": "quit"}
"""

import argparse
import json
import os
from pathlib import Path
import re
import sys
import threading

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstWebRTC", "1.0")
gi.require_version("GstSdp", "1.0")
gi.require_version("GstVideo", "1.0")
from gi.repository import GLib, Gst, GstSdp, GstVideo, GstWebRTC  # noqa: E402


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def render_path(pci):
    if not re.fullmatch(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]", pci):
        raise ValueError("VA-API requires a full PCI address, e.g. 0000:03:00.0")
    path = Path(f"/dev/dri/by-path/pci-{pci}-render")
    if not path.is_char_device() or not os.access(path, os.R_OK | os.W_OK):
        raise RuntimeError(f"No accessible VA-API render node for PCI {pci}")
    return path


def encoder_properties(name, bitrate, keyint):
    if name == "vaapih264enc":
        return f"bitrate={bitrate} keyframe-period={keyint} max-bframes=0 rate-control=cbr cpb-length=250"
    return f"bitrate={bitrate} key-int-max={keyint} b-frames=0 rate-control=cbr"


def pick_h264_encoder(render):
    node = render.resolve()
    for name in ("vah264enc", f"va{node.name}h264enc"):
        encoder = Gst.ElementFactory.make(name)
        if encoder is not None and encoder.find_property("device-path"):
            device = encoder.get_property("device-path")
            if device and Path(device).resolve() == node:
                return name
    if Gst.ElementFactory.find("vaapih264enc"):
        # Gst.init() already selected this process's PCI-specific DRM device.
        return "vaapih264enc"
    raise RuntimeError(f"No GStreamer VA-API H.264 encoder for {render}")


def crop_properties(region):
    x, y, width, height = region
    if min(x, y) < 0 or min(width, height) < 16 or width % 2 or height % 2:
        raise ValueError("Invalid X11 capture region")
    return f"startx={x} starty={y} endx={x + width - 1} endy={y + height - 1}"


def level31_size(width, height):
    """Largest even, aspect-preserving size within 3,600 macroblocks."""
    def fits(w, h):
        return ((w + 15) // 16) * ((h + 15) // 16) <= 3600 and max(w, h) <= 2704

    if fits(width, height):
        return width, height
    long_side = max(width, height)
    low, high = 1, long_side // 2
    while low < high:
        mid = (low + high + 1) // 2
        w = max(2, (width * mid // long_side) * 2)
        h = max(2, (height * mid // long_side) * 2)
        if fits(w, h):
            low = mid
        else:
            high = mid - 1
    return max(2, (width * low // long_side) * 2), max(2, (height * low // long_side) * 2)


class Agent:
    def __init__(self, args):
        self.args = args
        self.loop = GLib.MainLoop()
        self.pipe = None
        self.webrtc = None
        self.encoder = None
        self.remote_ice = []
        self.remote_description_set = False
        self.last_keyframe_request = 0

    def build(self):
        a = self.args
        props = encoder_properties(a.encoder, a.bitrate, a.fps * 2)
        stun = f"stun-server={json.dumps(a.stun)}" if a.stun else ""
        crop = crop_properties(a.region)
        _, _, width, height = a.region
        out_width, out_height = level31_size(width, height)

        video = (
            f"ximagesrc name=capture display-name={json.dumps(a.display)} use-damage=0 show-pointer=false {crop} "
            # ximagesrc can fall back to the root when the crop is out of bounds.
            f"! video/x-raw,framerate={a.fps}/1,width={width},height={height} "
            f"! queue max-size-buffers=2 max-size-bytes=0 max-size-time=0 leaky=downstream "
            f"! videoconvertscale ! video/x-raw,format=NV12,width={out_width},height={out_height},pixel-aspect-ratio=1/1 "
            f"! {a.encoder} name=encoder {props} "
            f"! video/x-h264,profile=constrained-baseline ! h264parse config-interval=-1 "
            f"! rtph264pay pt=96 config-interval=-1 aggregate-mode=zero-latency "
            f"! application/x-rtp,media=video,encoding-name=H264,payload=96 "
            f"! webrtcbin. "
        )
        audio = ""
        if a.audio_source and all(Gst.ElementFactory.find(name) for name in
                                  ("pulsesrc", "audioconvert", "audioresample", "opusenc", "rtpopuspay")):
            audio = (
                f"pulsesrc device={json.dumps(a.audio_source)} "
                f"! audioconvert ! audioresample "
                f"! opusenc bitrate=64000 inband-fec=true "
                f"! rtpopuspay pt=97 "
                f"! application/x-rtp,media=audio,encoding-name=OPUS,payload=97 "
                f"! webrtcbin. "
            )
        desc = (
            f"webrtcbin name=webrtcbin bundle-policy=max-bundle latency=0 {stun} "
            + video
            + audio
        )
        self.pipe = Gst.parse_launch(desc)
        self.webrtc = self.pipe.get_by_name("webrtcbin")
        self.encoder = self.pipe.get_by_name("encoder")
        source = self.pipe.get_by_name("capture")
        source.get_static_pad("src").add_probe(
            Gst.PadProbeType.EVENT_DOWNSTREAM, self.check_crop, source
        )
        self.webrtc.connect("on-negotiation-needed", self.on_negotiation_needed)
        self.webrtc.connect("on-ice-candidate", self.on_ice_candidate)
        self.webrtc.connect("notify::connection-state", self.on_conn_state)

        bus = self.pipe.get_bus()
        bus.add_signal_watch()
        bus.connect("message::error", self.on_bus_error)
        bus.connect("message::eos", lambda *_: self.fail("Capture ended"))

    def check_crop(self, _pad, info, source):
        if info.get_event().type == Gst.EventType.CAPS:
            x, y, width, height = self.args.region
            expected = (x, y, x + width - 1, y + height - 1)
            actual = tuple(source.get_property(key) for key in ("startx", "starty", "endx", "endy"))
            if actual != expected:
                GLib.idle_add(self.fail, "X11 capture region is outside the display")
                return Gst.PadProbeReturn.DROP
        return Gst.PadProbeReturn.OK

    # --- webrtcbin callbacks -------------------------------------------------

    def on_negotiation_needed(self, element):
        promise = Gst.Promise.new_with_change_func(self.on_offer_created, element)
        element.emit("create-offer", None, promise)

    def on_offer_created(self, promise, element):
        promise.wait()
        reply = promise.get_reply()
        offer = reply.get_value("offer") if reply and reply.has_field("offer") else None
        if offer is None:
            GLib.idle_add(self.fail, "GStreamer could not create an H.264 offer")
            return
        element.emit("set-local-description", offer, Gst.Promise.new())
        emit({"type": "offer", "sdp": offer.sdp.as_text()})

    def on_ice_candidate(self, _element, mline, candidate):
        emit({"type": "ice", "candidate": candidate, "sdpMLineIndex": int(mline)})

    def on_conn_state(self, element, _pspec):
        state = element.get_property("connection-state")
        emit({"type": "status", "state": state.value_nick})
        if state == GstWebRTC.WebRTCPeerConnectionState.FAILED:
            GLib.idle_add(self.fail, "WebRTC connection failed")

    def on_bus_error(self, _bus, msg):
        err, dbg = msg.parse_error()
        print(dbg, file=sys.stderr)
        self.fail(err.message)

    def fail(self, message):
        emit({"type": "error", "message": message})
        self.quit()

    # --- signaling from the host ---------------------------------------------

    def handle_line(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return
        kind = msg.get("type")
        if kind == "answer":
            result, sdpmsg = GstSdp.SDPMessage.new_from_text(msg["sdp"])
            if result != GstSdp.SDPResult.OK:
                self.fail("Invalid WebRTC answer")
                return
            answer = GstWebRTC.WebRTCSessionDescription.new(
                GstWebRTC.WebRTCSDPType.ANSWER, sdpmsg
            )
            promise = Gst.Promise.new_with_change_func(self.on_answer_set, None)
            self.webrtc.emit("set-remote-description", answer, promise)
        elif kind == "ice":
            candidate = (msg["sdpMLineIndex"], msg["candidate"])
            if self.remote_description_set:
                self.webrtc.emit("add-ice-candidate", *candidate)
            elif len(self.remote_ice) < 128:
                self.remote_ice.append(candidate)
        elif kind == "bitrate":
            self.encoder.set_property("bitrate", msg["kbps"])
        elif kind == "keyframe":
            now = GLib.get_monotonic_time()
            if now - self.last_keyframe_request >= 500_000:
                self.last_keyframe_request = now
                event = GstVideo.video_event_new_upstream_force_key_unit(Gst.CLOCK_TIME_NONE, True, 0)
                self.encoder.get_static_pad("src").send_event(event)
        elif kind == "quit":
            self.quit()

    def on_answer_set(self, promise, _data):
        reply = promise.get_reply()
        if reply and reply.has_field("error"):
            GLib.idle_add(self.fail, "GStreamer rejected the WebRTC answer")
        else:
            GLib.idle_add(self.flush_remote_ice)

    def flush_remote_ice(self):
        self.remote_description_set = True
        for candidate in self.remote_ice:
            self.webrtc.emit("add-ice-candidate", *candidate)
        self.remote_ice.clear()

    def stdin_reader(self):
        for line in sys.stdin:
            line = line.strip()
            if line:
                GLib.idle_add(self.handle_line, line)
        GLib.idle_add(self.quit)

    def quit(self):
        if self.pipe:
            self.pipe.set_state(Gst.State.NULL)
        self.loop.quit()

    def run(self):
        self.build()
        if self.pipe.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError("Could not start the GStreamer H.264 pipeline")
        threading.Thread(target=self.stdin_reader, daemon=True).start()
        emit({"type": "status", "state": "starting"})
        self.loop.run()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--display")
    parser.add_argument("--region", nargs=4, type=int)
    parser.add_argument("--pci", default="0000:03:00.0")
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--bitrate", type=int, default=4000, help="video kbps")
    parser.add_argument("--audio-source", default=None)
    parser.add_argument("--stun", default=None, help="stun://host:port")
    args = parser.parse_args()

    try:
        render = render_path(args.pci)
        os.environ["GST_VAAPI_DRM_DEVICE"] = str(render)
        os.environ.pop("DISPLAY", None)
        os.environ.pop("WAYLAND_DISPLAY", None)
        Gst.init(None)
        required = ("ximagesrc", "videoconvertscale", "h264parse", "rtph264pay",
                    "webrtcbin", "nicesrc", "dtlssrtpenc", "srtpenc")
        missing = [name for name in required if not Gst.ElementFactory.find(name)]
        if missing:
            raise RuntimeError(f"Missing GStreamer elements: {', '.join(missing)}")
        args.encoder = pick_h264_encoder(render)
        if args.probe:
            emit({"type": "available", "encoder": args.encoder, "render": str(render)})
        else:
            if not args.display or not args.region or not 10 <= args.fps <= 30:
                raise ValueError("Expected an X11 display, a capture region and 10–30 fps")
            Agent(args).run()
    except (GLib.Error, RuntimeError, ValueError) as error:
        emit({"type": "error", "message": str(error)})
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
