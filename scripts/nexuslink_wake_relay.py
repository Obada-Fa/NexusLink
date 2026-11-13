#!/usr/bin/env python3
"""Authenticated, single-PC Wake-on-LAN relay for an always-on home server."""
import argparse
import hmac
import ipaddress
import json
from pathlib import Path
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def magic_packet(mac):
    if not re.fullmatch(r'(?:[0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}', mac):
        raise ValueError('Invalid MAC address')
    return b'\xff' * 6 + bytes.fromhex(mac.replace(':', '').replace('-', '')) * 16


def make_handler(token, mac, broadcast, port=9, send=None):
    packet = magic_packet(mac)
    ipaddress.IPv4Address(broadcast)
    lock = threading.Lock()
    last_sent = [float('-inf')]

    def wake():
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
            sender.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            for _ in range(3):
                sender.sendto(packet, (broadcast, port))
                time.sleep(.1)

    class Handler(BaseHTTPRequestHandler):
        def reply(self, status, body):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.reply(200, {'service': 'nexuslink-wake', 'ready': True}) if self.path == '/health' else self.reply(404, {'error': 'Not found'})

        def do_POST(self):
            if self.path != '/wake':
                return self.reply(404, {'error': 'Not found'})
            supplied = self.headers.get('X-API-Key', '')
            if not hmac.compare_digest(supplied.encode(), token.encode()):
                return self.reply(401, {'error': 'Unauthorized'})
            try:
                length = int(self.headers.get('Content-Length', '0'))
            except ValueError:
                return self.reply(400, {'error': 'Invalid length'})
            if not 0 <= length <= 4096 or self.headers.get('Transfer-Encoding'):
                return self.reply(413, {'error': 'Request too large'})
            self.rfile.read(length)  # The request cannot change the configured target.
            with lock:
                if time.monotonic() - last_sent[0] < 3:
                    return self.reply(429, {'error': 'Please wait before waking again'})
                try:
                    (send or wake)()
                except OSError:
                    return self.reply(503, {'error': 'LAN wake packet could not be sent'})
                last_sent[0] = time.monotonic()
            self.reply(200, {'status': 'success', 'message': 'Wake packet sent'})

        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def log_message(self, *_):
            pass  # Never log credentials, request URLs, or body content.

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=3050)
    parser.add_argument('--mac', required=True)
    parser.add_argument('--broadcast', required=True)
    parser.add_argument('--token-file', required=True)
    args = parser.parse_args()
    token = Path(args.token_file).read_text().strip()
    if len(token) < 20:
        parser.error('Use an API key with at least 20 characters')
    server = ThreadingHTTPServer((args.bind, args.port), make_handler(token, args.mac, args.broadcast))
    server.daemon_threads = True
    server.serve_forever()


if __name__ == '__main__':
    main()
