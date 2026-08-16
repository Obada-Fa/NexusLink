#!/usr/bin/env python3
"""NexusLink WebRTC encoder agent.

One process per stream: captures an X display (a virtual app session's screen)
with ximagesrc, encodes H.264 (VA-API/NVENC when present, x264 zerolatency
otherwise) plus optional Opus audio from a PulseAudio monitor source, and
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
import sys
import threading

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GstWebRTC", "1.0")
gi.require_version("GstSdp", "1.0")
from gi.repository import GLib, Gst, GstSdp, GstWebRTC  # noqa: E402


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def pick_h264_encoder(bitrate_kbps, keyint):
    """Prefer hardware encoders; fall back to zerolatency x264."""
    for name in ("vah264enc", "vaapih264enc", "nvh264enc"):
        if Gst.ElementFactory.find(name):
            if name == "nvh264enc":
                return f"{name} preset=low-latency-hq bitrate={bitrate_kbps} gop-size={keyint}"
            return f"{name} bitrate={bitrate_kbps} key-int-max={keyint}"
    return (
        f"x264enc tune=zerolatency speed-preset=ultrafast bitrate={bitrate_kbps} "
        f"key-int-max={keyint} byte-stream=true threads=4"
    )


class Agent:
    def __init__(self, args):
        self.args = args
        self.loop = GLib.MainLoop()
        self.pipe = None
        self.webrtc = None

    def build(self):
        a = self.args
        keyint = a.fps * 2
        enc = pick_h264_encoder(a.bitrate, keyint)
        stun = f"stun-server={a.stun}" if a.stun else ""

        video = (
            f"ximagesrc display-name={a.display} use-damage=0 show-pointer=true "
            f"! video/x-raw,framerate={a.fps}/1 "
            f"! videoconvert ! queue max-size-buffers=2 leaky=downstream "
            f"! {enc} "
            f"! video/x-h264,profile=constrained-baseline ! h264parse config-interval=-1 "
            f"! rtph264pay pt=96 config-interval=-1 aggregate-mode=zero-latency "
            f"! application/x-rtp,media=video,encoding-name=H264,payload=96 "
            f"! webrtcbin. "
        )
        audio = ""
        if a.audio_source:
            audio = (
                f"pulsesrc device={a.audio_source} "
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
        self.webrtc.connect("on-negotiation-needed", self.on_negotiation_needed)
        self.webrtc.connect("on-ice-candidate", self.on_ice_candidate)
        self.webrtc.connect("notify::connection-state", self.on_conn_state)

        bus = self.pipe.get_bus()
        bus.add_signal_watch()
        bus.connect("message::error", self.on_bus_error)
        bus.connect("message::eos", lambda *_: self.quit())

    # --- webrtcbin callbacks -------------------------------------------------

    def on_negotiation_needed(self, element):
        promise = Gst.Promise.new_with_change_func(self.on_offer_created, element)
        element.emit("create-offer", None, promise)

    def on_offer_created(self, promise, element):
        promise.wait()
        reply = promise.get_reply()
        offer = reply.get_value("offer")
        element.emit("set-local-description", offer, Gst.Promise.new())
        emit({"type": "offer", "sdp": offer.sdp.as_text()})

    def on_ice_candidate(self, _element, mline, candidate):
        emit({"type": "ice", "candidate": candidate, "sdpMLineIndex": int(mline)})

    def on_conn_state(self, element, _pspec):
        state = element.get_property("connection-state")
        emit({"type": "status", "state": state.value_nick})
        if state == GstWebRTC.WebRTCPeerConnectionState.FAILED:
            self.quit()

    def on_bus_error(self, _bus, msg):
        err, dbg = msg.parse_error()
        emit({"type": "error", "message": f"{err.message} ({dbg})"})
        self.quit()

    # --- signaling from the host ---------------------------------------------

    def handle_line(self, line):
        try:
            msg = json.loads(line)
        except ValueError:
            return
        kind = msg.get("type")
        if kind == "answer":
            _res, sdpmsg = GstSdp.SDPMessage.new_from_text(msg["sdp"])
            answer = GstWebRTC.WebRTCSessionDescription.new(
                GstWebRTC.WebRTCSDPType.ANSWER, sdpmsg
            )
            self.webrtc.emit("set-remote-description", answer, Gst.Promise.new())
        elif kind == "ice":
            self.webrtc.emit(
                "add-ice-candidate", int(msg.get("sdpMLineIndex", 0)), msg["candidate"]
            )
        elif kind == "quit":
            self.quit()

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
        self.pipe.set_state(Gst.State.PLAYING)
        threading.Thread(target=self.stdin_reader, daemon=True).start()
        emit({"type": "status", "state": "starting"})
        self.loop.run()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--display", required=True)
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--bitrate", type=int, default=4000, help="video kbps")
    parser.add_argument("--audio-source", default=None)
    parser.add_argument("--stun", default=None, help="stun://host:port")
    args = parser.parse_args()

    Gst.init(None)
    Agent(args).run()


if __name__ == "__main__":
    main()
