import importlib.util
from pathlib import Path
import threading
import unittest
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer

spec=importlib.util.spec_from_file_location('relay',Path(__file__).with_name('nexuslink_wake_relay.py'))
relay=importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)

class WakeRelayTest(unittest.TestCase):
    def test_authorization_target_and_rate_limit(self):
        sent=[]
        handler=relay.make_handler('a'*32,'BC:FC:E7:1A:1D:AA','192.168.68.255',send=lambda:sent.append(True))
        server=ThreadingHTTPServer(('127.0.0.1',0),handler)
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        def post(key):
            request=urllib.request.Request(f'http://127.0.0.1:{server.server_port}/wake',data=b'{}',headers={'X-API-Key':key})
            try:
                with urllib.request.urlopen(request,timeout=2) as response:return response.status
            except urllib.error.HTTPError as error:return error.code
        try:
            self.assertEqual(post('wrong'),401);self.assertEqual(sent,[])
            self.assertEqual(post('a'*32),200);self.assertEqual(sent,[True])
            self.assertEqual(post('a'*32),429);self.assertEqual(sent,[True])
        finally:server.shutdown();server.server_close();worker.join()
    def test_magic_packet(self):
        packet=relay.magic_packet('BC:FC:E7:1A:1D:AA')
        self.assertEqual(len(packet),102)
        self.assertEqual(packet[:6],b'\xff'*6)
        self.assertEqual(packet[6:],bytes.fromhex('BCFCE71A1DAA')*16)

if __name__=='__main__':unittest.main()
