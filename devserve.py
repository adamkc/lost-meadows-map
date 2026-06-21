#!/usr/bin/env python3
"""Local dev server for the site/ folder WITH HTTP range-request support.

Python's stock http.server doesn't serve byte ranges, which PMTiles requires.
GitHub Pages serves ranges fine, so this is only needed for local preview.

Usage:  python devserve.py [port]   (defaults to 8001; serves ./site)
"""
import functools, http.server, os, re, sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
DIRECTORY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "site")


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        rng = self.headers.get("Range")
        path = self.translate_path(self.path)
        if not rng or not os.path.isfile(path):
            return super().do_GET()
        size = os.path.getsize(path)
        m = re.match(r"bytes=(\d+)-(\d*)", rng)
        if not m:
            return super().do_GET()
        start = int(m.group(1))
        end = int(m.group(2)) if m.group(2) else size - 1
        end = min(end, size - 1)
        if start > end:
            self.send_error(416)
            return
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            self.wfile.write(f.read(end - start + 1))


if __name__ == "__main__":
    handler = functools.partial(RangeHandler, directory=DIRECTORY)
    print(f"Serving {DIRECTORY} with range support on http://localhost:{PORT}")
    http.server.ThreadingHTTPServer(("", PORT), handler).serve_forever()
