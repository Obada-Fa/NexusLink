#!/usr/bin/env python3
"""Tiny PTY host for NexusLink terminals.

Bun has no built-in PTY, so this helper owns one: it spawns the shell on a
real pseudo-terminal (job control, colors, resize — everything a pipe-based
shell lacks) and bridges it to the Bun server over stdio.

Protocol:
  stdin  <- JSON lines: {"t":"d","d":"<base64 bytes>"}   keyboard input
                        {"t":"r","c":<cols>,"r":<rows>}  resize (TIOCSWINSZ)
  stdout -> raw PTY output bytes (unframed)
"""

import base64
import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios

def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def main():
    shell = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SHELL", "/bin/bash")
    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 80
    rows = int(sys.argv[3]) if len(sys.argv) > 3 else 24

    pid, master = pty.fork()
    if pid == 0:
        env = dict(os.environ, TERM="xterm-256color")
        os.execvpe(shell, [shell, "-l"], env)
        os._exit(1)

    set_winsize(master, rows, cols)
    signal.signal(signal.SIGCHLD, lambda *_: None)

    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()
    inbuf = b""

    while True:
        try:
            ready, _, _ = select.select([master, stdin_fd], [], [])
        except InterruptedError:
            continue

        if master in ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            os.write(stdout_fd, data)

        if stdin_fd in ready:
            chunk = os.read(stdin_fd, 65536)
            if not chunk:
                break  # Bun closed us; take the shell down too
            inbuf += chunk
            while b"\n" in inbuf:
                line, inbuf = inbuf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("t") == "d":
                    os.write(master, base64.b64decode(msg["d"]))
                elif msg.get("t") == "r":
                    set_winsize(master, int(msg["r"]), int(msg["c"]))
                    try:
                        os.kill(pid, signal.SIGWINCH)
                    except ProcessLookupError:
                        pass

    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass


if __name__ == "__main__":
    main()
