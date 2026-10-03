#!/usr/bin/env python3
"""Real PTY bridge: JSON input messages d (base64), r (resize), k (terminate).
Output is raw UTF-8 bytes; the parent preserves decoder state across chunks.
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
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))


def write_all(fd, data):
    view = memoryview(data)
    while view:
        try:
            count = os.write(fd, view)
            if count == 0:
                raise BrokenPipeError('PTY write made no progress')
            view = view[count:]
        except InterruptedError:
            continue


def main():
    shell = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('SHELL', '/bin/bash')
    cols, rows = int(sys.argv[2]), int(sys.argv[3])
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.execvpe(shell, [shell, '-l'], dict(os.environ, TERM='xterm-256color'))
        except OSError as error:
            print(f'Cannot start shell: {error}', file=sys.stderr)
            os._exit(127)

    def stop(*_):
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGHUP, stop)
    set_winsize(master, rows, cols)
    inbuf = b''
    try:
        while True:
            try:
                ready, _, _ = select.select([master, sys.stdin.fileno()], [], [])
            except InterruptedError:
                continue
            if master in ready:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                write_all(sys.stdout.fileno(), data)
            if sys.stdin.fileno() in ready:
                chunk = os.read(sys.stdin.fileno(), 65536)
                if not chunk:
                    return 143
                inbuf += chunk
                if len(inbuf) > 1024 * 1024:
                    raise ValueError('PTY input frame exceeds limit')
                while b'\n' in inbuf:
                    line, inbuf = inbuf.split(b'\n', 1)
                    if not line.strip():
                        continue
                    msg = json.loads(line)
                    if msg.get('t') == 'k':
                        return 143
                    if msg.get('t') == 'd':
                        write_all(master, base64.b64decode(msg['d'], validate=True))
                    elif msg.get('t') == 'r':
                        set_winsize(master, int(msg['r']), int(msg['c']))
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status)
    finally:
        os.close(master)
        # Kill the original shell group, including background jobs. Closing a
        # view never invokes this path; only exit, host shutdown or terminate.
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


if __name__ == '__main__':
    sys.exit(main())
