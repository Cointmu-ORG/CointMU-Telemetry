"""Stub geth JSON-RPC for check-chain.sh, on 127.0.0.1 inside the fake node
container. Never run on a real node.

    stub-rpc.py <port> <role>

Answers the calls chain-metrics.py makes, single or batched. Blocks come every
BLOCK_TIME_SECONDS on the wall clock, so every stub has the same head. The
scenario is read from /tmp/stub/<role> on every request (default healthy):
    healthy  in sync, 2 peers, newest block at most one block time old
    behind   20 blocks behind
    peers0   no peers
    stalled  every block 900 s older, as if no block came for 15 minutes
    down     HTTP 503 to everything
"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BLOCK_TIME_SECONDS = 14
DIFFICULTY = 2355889
HEALTHY_PEERS = 2
BEHIND_BLOCKS = 20
STALLED_SECONDS = 900
SERVICE_UNAVAILABLE = 503
SCENARIO_DIR = Path("/tmp/stub")


def scenario(role: str) -> str:
    try:
        return (SCENARIO_DIR / role).read_text().strip() or "healthy"
    except FileNotFoundError:
        return "healthy"


def block(number: int, state: str) -> dict:
    shift = STALLED_SECONDS if state == "stalled" else 0
    return {"number": hex(number), "timestamp": hex(number * BLOCK_TIME_SECONDS - shift),
            "difficulty": hex(DIFFICULTY)}


def answer(call: dict, state: str) -> dict:
    head = int(time.time()) // BLOCK_TIME_SECONDS - (BEHIND_BLOCKS if state == "behind" else 0)
    method, params = call["method"], call.get("params", [])
    if method == "eth_getBlockByNumber":
        result = block(head if params[0] == "latest" else int(params[0], 16), state)
    elif method == "net_peerCount":
        result = hex(0 if state == "peers0" else HEALTHY_PEERS)
    elif method == "eth_syncing":
        result = False
    else:
        return {"jsonrpc": "2.0", "id": call["id"], "error": {"code": -32601, "message": "not stubbed"}}
    return {"jsonrpc": "2.0", "id": call["id"], "result": result}


def handler_for(role: str) -> type:
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:
            state = scenario(role)
            if state == "down":
                self.send_error(SERVICE_UNAVAILABLE)
                return
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            reply = [answer(c, state) for c in request] if isinstance(request, list) else answer(request, state)
            body = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_: object) -> None:
            pass

    return Handler


if __name__ == "__main__":
    port, role = int(sys.argv[1]), sys.argv[2]
    ThreadingHTTPServer(("127.0.0.1", port), handler_for(role)).serve_forever()
