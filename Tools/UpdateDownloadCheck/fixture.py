"""A local release-sized transfer, slow enough to cancel after receiving bytes."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        size = 1024 * 1024
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        try:
            for _ in range(size // 16384):
                self.wfile.write(b"x" * 16384)
                self.wfile.flush()
                time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
