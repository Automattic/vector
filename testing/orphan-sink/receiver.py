#!/usr/bin/env python3
"""HTTP receiver for the orphaned-sink repro.

Answers every request with STATUS (default 200) and logs one line per request with a
unix timestamp, so the harness can count requests in a time window via `docker logs`.
Env vars:
  PORT    listen port (default 8001)
  STATUS  HTTP status to return (e.g. 429 for a permanently failing, retriable destination)
"""
import http.server
import os
import socketserver
import time

PORT = int(os.environ.get("PORT", "8001"))
STATUS = int(os.environ.get("STATUS", "200"))


class Handler(http.server.BaseHTTPRequestHandler):
    def _h(self):
        try:
            ln = int(self.headers.get("Content-Length", "0") or "0")
            if ln > 0:
                self.rfile.read(ln)
        except Exception:
            pass
        self.send_response(STATUS)
        self.send_header("Content-Length", "0")
        self.end_headers()
        print(f"REQ {time.time():.3f} {STATUS}", flush=True)

    do_GET = do_POST = do_PUT = _h

    def log_message(self, *a, **kw):
        pass


print(f"receiver listening on {PORT} (status {STATUS})", flush=True)
with socketserver.ThreadingTCPServer(("", PORT), Handler) as srv:
    srv.serve_forever()
