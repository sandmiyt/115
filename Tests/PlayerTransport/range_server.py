"""Deterministic HTTP adversary; never accesses cloud credentials."""
import argparse
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
SIZE = 3 * 1048576 + 97

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, *args):
        import traceback
        traceback.print_exc()  # Fixture-only failures, no private media/credentials.

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/timeout": time.sleep(14)
        if path == "/expired":
            self.send_response(403); self.send_header("Content-Length", "0"); self.end_headers(); return
        if path == "/redirect":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{self.server.server_port}/credential-check")
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if path == "/credential-check" and (self.headers.get("User-Agent") != "Cineva-iOS/2.0" or any(self.headers.get(k) for k in ("Authorization", "Cookie", "X-Private", "Referer", "Origin"))):
            self.send_response(400); self.send_header("Content-Length", "0"); self.end_headers(); return
        first, last = self.headers.get("Range", "bytes=0-").removeprefix("bytes=").split("-")
        start = int(first); total = 131072 if path == "/small200" else SIZE
        end = min(int(last) if last else total - 1, total - 1)
        if path == "/416" or start >= total:
            self.send_response(416); self.send_header("Content-Range", f"bytes */{total}")
            self.send_header("Content-Length", "0"); self.end_headers(); return
        if path in ("/short64", "/short10", "/shortchange"):
            end = min(end, start + (65536 if path == "/short64" else 10000) - 1)
        if path in ("/overbody", "/underbody"):
            end = min(end, start + 9999)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            self.send_header("ETag", '"v1"')
            self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            payload = bytes(i % 251 for i in range(start, end + 1 + (1 if path == "/overbody" else -1)))
            self.wfile.write(f"{len(payload):x}\r\n".encode() + payload + b"\r\n0\r\n\r\n")
            self.wfile.flush(); return
        status = 200 if path in ("/bad200", "/small200") else 206
        if status == 200: start, end = 0, total - 1
        self.send_response(status); self.send_header("Content-Length", str(end - start + 1 + (1 if path == "/badlength" else 0)))
        if status == 206:
            declared = start + 1 if path == "/wrongrange" else start
            self.send_header("Content-Range", f"bytes {declared}-{end}/{total}")
        if path != "/novalidator" and not (path == "/missingetag" and start >= 1048576):
            changed = path == "/v2" or (path == "/changed" and start >= 1048576) or (path == "/shortchange" and start >= 10000)
            self.send_header("ETag", '"v2"' if changed else '"v1"')
        self.end_headers()
        for pos in range(start, end + 1, 16384):
            self.wfile.write(bytes(i % 251 for i in range(pos, min(pos + 16384, end + 1))))
            self.wfile.flush()
            if path == "/cut":
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
            if path == "/slow": time.sleep(0.04)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--port-file", required=True)
    args = parser.parse_args(); server = Server(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w", encoding="ascii") as file: file.write(str(server.server_port))
    server.serve_forever()
