"""Deterministic HTTP adversary; never accesses cloud credentials."""
from pathlib import Path
import argparse
import socket
import time
import threading
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
SIZE = 3 * 1048576 + 97

class Server(ThreadingHTTPServer):
    daemon_threads = True
    attempts = {}
    attempts_lock = threading.Lock()
    def handle_error(self, *args):
        import traceback, sys
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)): return
        traceback.print_exc()  # Fixture-only failures, no private media/credentials.

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def do_GET(self):
        path = self.path.split("?")[0]
        if path.startswith("/media/"):
            media = Path(self.server.media_dir) / Path(path).name
            if not media.is_file(): self.send_error(404); return
            size = media.stat().st_size
            raw = self.headers.get("Range", f"bytes=0-{size-1}")[6:].split("-")
            start, end = int(raw[0]), min(int(raw[1]) if len(raw)>1 and raw[1] else size-1, size-1)
            if start >= size:
                self.send_response(416); self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0"); self.end_headers(); return
            self.send_response(206); self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.send_header("Content-Length", str(end-start+1)); self.send_header("ETag", f'"fixture-{media.name}-{size}"')
            self.end_headers()
            try:
                with media.open("rb") as data:
                    data.seek(start); remaining=end-start+1
                    while remaining:
                        chunk=data.read(min(65536, remaining)); self.wfile.write(chunk); remaining-=len(chunk)
            except (BrokenPipeError, ConnectionResetError): pass
            return
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
        start = int(first); total = 131072 if path == "/small200" else (576 * 1048576 + 97 if path == "/large" else SIZE)
        end = min(int(last) if last else total - 1, total - 1)
        if path.startswith("/retry-"):
            key = (self.path, start)
            with self.server.attempts_lock:
                attempt = self.server.attempts.get(key, 0) + 1
                self.server.attempts[key] = attempt
            transient = {"/retry-once": (500, 1), "/retry-twice": (500, 2),
                         "/retry-forever": (500, 99), "/retry-502": (502, 1),
                         "/retry-504": (504, 1), "/retry-503": (503, 1),
                         "/retry-429": (429, 1), "/retry-date": (503, 1),
                         "/retry-huge": (429, 99), "/retry-stop": (503, 99),
                         "/retry-cache": (500, 1), "/retry-version": (500, 1),
                         "/retry-404": (404, 99)}
            code, failures = transient.get(path, (500, 0))
            if path == "/retry-auth-cap": code, failures = (500 if attempt <= 2 else 403), 99
            eligible = path not in ("/retry-cache", "/retry-version", "/retry-stop") or start >= 1048576
            if eligible and attempt <= failures:
                self.send_response(code)
                if path == "/retry-date": self.send_header("Retry-After", formatdate(time.time()+2, usegmt=True))
                elif path == "/retry-huge": self.send_header("Retry-After", "999999999999999999999999999")
                elif path in ("/retry-503", "/retry-429", "/retry-stop", "/retry-cache"): self.send_header("Retry-After", "1")
                body = b"THIS IS AN ERROR PAGE, NOT MEDIA"
                self.send_header("Content-Length", str(len(body))); self.end_headers()
                try: self.wfile.write(body); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError): pass
                return
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
            changed = path == "/v2" or (path == "/retry-version" and start >= 1048576) or (path == "/changed" and start >= 1048576) or (path == "/shortchange" and start >= 10000)
            self.send_header("ETag", '"v2"' if changed else '"v1"')
        self.end_headers()
        for pos in range(start, end + 1, 16384):
            count = min(16384, end + 1 - pos)
            pattern = bytes(range(251)) * 67
            self.wfile.write(pattern[pos % 251:pos % 251 + count])
            self.wfile.flush()
            if path == "/cut":
                self.connection.shutdown(socket.SHUT_RDWR); self.connection.close(); return
            if path == "/slow": time.sleep(0.04)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--port-file", required=True)
    parser.add_argument("--media-dir", default="")
    args = parser.parse_args(); server = Server(("127.0.0.1", 0), Handler)
    server.media_dir=args.media_dir
    with open(args.port_file, "w", encoding="ascii") as file: file.write(str(server.server_port))
    server.serve_forever()
