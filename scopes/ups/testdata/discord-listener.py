"""Stand-in for discord.com in check-notify.sh: accepts webhook POSTs over
HTTPS and appends one JSON line per request (receive time, path, body) to the
log file. If the delay file holds a number, it waits that many seconds before
answering 204, to test the notifier's timeouts.

    python3 discord-listener.py <cert> <key> <log file> <delay file>
"""
import json
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

CERT, KEY, LOG, DELAY = sys.argv[1:5]
HTTPS_PORT = 443
NO_CONTENT = 204


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        received = time.time()
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(LOG, "a", encoding="utf-8") as log:
            log.write(json.dumps({"time": received, "path": self.path, "body": body.decode()}) + "\n")
        delay = Path(DELAY).read_text().strip() if Path(DELAY).exists() else ""
        if delay:
            time.sleep(float(delay))
        self.send_response(NO_CONTENT)
        self.end_headers()

    def log_message(self, *args: object) -> None:
        pass


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(CERT, KEY)
server = ThreadingHTTPServer(("127.0.0.1", HTTPS_PORT), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
