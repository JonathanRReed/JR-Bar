"""Apple transport parity, including the redirect callback's native ABI."""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from jrbar.claude_quota import request_via_apple_stack


@pytest.mark.skipif(sys.platform != "darwin", reason="NSURLSession")
def test_native_transport_keeps_same_origin_redirects_and_refuses_cross_origin():
    forwarded = []

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            self.send_response(200)
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path in {"/same", "/cross"}:
                destination = source.server_port if self.path == "/same" else other.server_port
                self.send_response(302)
                self.send_header("Location", f"http://127.0.0.1:{destination}/final")
                self.end_headers()
            else:
                forwarded.append((self.server.server_port, self.headers.get("Authorization")))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"ok":true}')

        def log_message(self, *args):
            pass

    source = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    other = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in (source, other)]
    for thread in threads:
        thread.start()
    try:
        root = f"http://127.0.0.1:{source.server_port}"
        request_via_apple_stack(root + "/final", method="GET", headers={"Authorization": "Bearer synthetic"}, timeout=3)
        assert forwarded == [(source.server_port, "Bearer synthetic")]
        status, body = request_via_apple_stack(root + "/same", method="GET", headers={"Authorization": "Bearer synthetic"}, timeout=3)
        assert status == 200 and json.loads(body) == {"ok": True}
        assert len(forwarded) == 2 and forwarded[-1][0] == source.server_port
        status, body = request_via_apple_stack(root + "/echo", method="POST", headers={}, body=b'{"synthetic":true}', timeout=3)
        assert status == 200 and body == b'{"synthetic":true}'
        status, _ = request_via_apple_stack(root + "/cross", method="GET", headers={"Authorization": "Bearer synthetic"}, timeout=3)
        assert status == 302
        assert len(forwarded) == 2
        from jrbar import native_apple_http

        assert native_apple_http._callbacks == {}
        assert native_apple_http._origins == {}
    finally:
        for server in (source, other):
            server.shutdown()
            server.server_close()
        for thread in threads:
            thread.join(timeout=3)
