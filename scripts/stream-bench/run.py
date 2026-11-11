#!/usr/bin/env python3
"""Run the NexusLink stream benchmark with a private display and Chrome profile."""

import argparse
from contextlib import ExitStack, contextmanager
from itertools import product
import json
import os
from pathlib import Path
import secrets
import select
import signal
import statistics
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
TARGETS = {
    # (Xvfb width, Xvfb height), (capture x, y, width, height)
    "virtual": ((720, 1280), (0, 0, 720, 1280)),
    "window": ((1920, 1080), (100, 80, 1100, 850)),
    "desktop": ((1920, 1080), (0, 0, 1920, 1080)),
}
SCENES = ("static", "scrolling")


@contextmanager
def child(command, env, log, pass_fds=()):
    with log.open("w") as stderr:
        proc = subprocess.Popen(
            command, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=stderr, pass_fds=pass_fds, text=True,
        )
        try:
            yield proc.stdout
        finally:
            if proc.poll() is None:
                proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            proc.stdout.close()


def read_line(stream, timeout, description):
    if not select.select([stream], [], [], timeout)[0]:
        raise RuntimeError(f"Timed out waiting for {description}")
    line = stream.readline().strip()
    if not line:
        raise RuntimeError(f"Process exited before {description}")
    return line


def run(target, scene, chrome, codec, check_fallback, check_qos, scratch):
    (screen_w, screen_h), region = TARGETS[target]
    display_number = 1000 + secrets.randbelow(8000)
    authority = scratch / "Xauthority"
    authority.touch(mode=0o600)
    env = dict(os.environ)
    env.pop("WAYLAND_DISPLAY", None)
    env.update(
        DISPLAY=f":{display_number}",
        XAUTHORITY=str(authority),
        NEXUSLINK_BENCH_XAUTHORITY=str(authority),
        HOME=str(scratch),
        XDG_CONFIG_HOME=str(scratch / "config"),
        XDG_CACHE_HOME=str(scratch / "cache"),
        XDG_DATA_HOME=str(scratch / "data"),
        XDG_RUNTIME_DIR=str(scratch / "runtime"),
        NEXUSLINK_DATA_DIR=str(scratch / "nexus-data"),
        NEXUSLINK_STUN="",
        DBUS_SESSION_BUS_ADDRESS=f"unix:path={scratch / 'unused-bus'}",
    )
    (scratch / "runtime").mkdir(mode=0o700)
    subprocess.run(
        ["xauth", "-q", "add", env["DISPLAY"], "MIT-MAGIC-COOKIE-1", secrets.token_hex(16)],
        env=env, check=True, timeout=5,
    )
    with ExitStack() as stack:
        read_fd, write_fd = os.pipe()
        ready = stack.enter_context(os.fdopen(read_fd))
        try:
            stack.enter_context(child(
                ["Xvfb", env["DISPLAY"], "-displayfd", str(write_fd), "-nolisten", "tcp",
                 "-auth", str(authority), "-screen", "0", f"{screen_w}x{screen_h}x24"],
                env, scratch / "Xvfb.log", pass_fds=(write_fd,),
            ))
        finally:
            os.close(write_fd)
        if read_line(ready, 8, "Xvfb readiness") != str(display_number):
            raise RuntimeError("Xvfb reported an unexpected display")

        app = stack.enter_context(child(
            [sys.executable, HERE / "scene.py", *map(str, region), scene],
            env, scratch / "scene.log",
        ))
        read_line(app, 8, "scene readiness")
        server = stack.enter_context(child(
            ["bun", HERE / "server.ts", target, *map(str, region)],
            env, scratch / "server.log",
        ))
        port = int(read_line(server, 8, "benchmark server port"))
        query = f"codec={codec}&fallback={int(check_fallback)}&qos={int(check_qos)}"
        stack.enter_context(child(
            [chrome, "--headless", "--disable-gpu", "--disable-background-networking",
             "--disable-features=WebRtcHideLocalIpsWithMdns",
             "--no-first-run", f"--user-data-dir={scratch / 'chrome'}",
             f"http://127.0.0.1:{port}/?{query}"],
            env, scratch / "chrome.log",
        ))
        message = json.loads(read_line(server, 45, "browser benchmark result"))
        if "error" in message:
            raise RuntimeError(message["error"])

    result = message["result"]
    result["tapMedianMs"] = statistics.median(result["tapMs"])
    result["tapMaxMs"] = max(result["tapMs"])
    return dict(target=target, scene=scene, codec=codec, **result)


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=(*TARGETS, "all"), default="all")
    parser.add_argument("--scene", choices=(*SCENES, "all"), default="all")
    parser.add_argument("--chrome", default="google-chrome")
    parser.add_argument("--codec", choices=("mjpeg", "h264", "both"), default="mjpeg")
    parser.add_argument("--check-fallback", action="store_true",
                        help="After each H.264 sample, stop the peer and check JPEG resumes")
    parser.add_argument("--check-qos", action="store_true",
                        help="After each H.264 sample, verify zoom and congestion change the bitrate")
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    targets = TARGETS if args.target == "all" else (args.target,)
    scenes = SCENES if args.scene == "all" else (args.scene,)
    codecs = ("mjpeg", "h264") if args.codec == "both" else (args.codec,)
    for target, scene, codec in product(targets, scenes, codecs):
        with tempfile.TemporaryDirectory(prefix="nexus-stream-bench-") as directory:
            scratch = Path(directory)
            try:
                result = run(
                    target, scene, args.chrome, codec, args.check_fallback, args.check_qos, scratch
                )
            except Exception as error:
                print(f"{target}/{scene}/{codec}: {error}", file=sys.stderr)
                for log in sorted(scratch.glob("*.log")):
                    tail = "\n".join(log.read_text(errors="replace").splitlines()[-12:])
                    if tail:
                        print(f"{log.name}\n{tail}", file=sys.stderr)
                return 1
            print(json.dumps(result), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
