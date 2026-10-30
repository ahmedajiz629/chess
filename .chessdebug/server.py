"""Tiny telemetry collector for the Chess Tracker.

The Flutter app (running in the user's browser at :8080) POSTs debug data here.
We write it to flat files so Claude can Read/Grep/analyze while the user
physically manipulates the board.

Files written next to this script:
  events.jsonl        append-only, one JSON object per line (frames + events)
  state.json          the most recent per-frame snapshot (overwritten)
  snapshots/*.png     annotated camera frames (so Claude can *see* the board)
  snapshots/latest.txt filename of the newest snapshot

Run:  python server.py [port]   (default 8181)
"""

import base64
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
SNAP_DIR = os.path.join(HERE, "snapshots")
EVENTS = os.path.join(HERE, "events.jsonl")
STATE = os.path.join(HERE, "state.json")
os.makedirs(SNAP_DIR, exist_ok=True)


def _now_ms():
    return int(time.time() * 1000)


class Handler(BaseHTTPRequestHandler):
    # Silence the default per-request stderr logging.
    def log_message(self, fmt, *args):
        pass

    def _cors(self, code=200):
        self.send_response(code)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Content-Type", "text/plain")
        self.end_headers()

    def do_OPTIONS(self):
        self._cors(204)

    def do_GET(self):
        self._cors(200)
        self.wfile.write(b"chessdebug collector ok")

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        return raw.decode("utf-8", "replace")

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self._read_body()
        try:
            if path == "/events":
                self._handle_events(body)
            elif path == "/snapshot":
                self._handle_snapshot(body)
            elif path == "/reset":
                open(EVENTS, "w").close()
                self._cors(200)
                self.wfile.write(b"reset")
                return
            else:
                self._cors(404)
                return
        except Exception as e:  # keep the collector alive no matter what
            self._cors(500)
            self.wfile.write(str(e).encode())
            return
        self._cors(200)
        self.wfile.write(b"ok")

    def _handle_events(self, body):
        data = json.loads(body)
        items = data if isinstance(data, list) else [data]
        with open(EVENTS, "a", encoding="utf-8") as f:
            for item in items:
                if "t" not in item:
                    item["t"] = _now_ms()
                f.write(json.dumps(item) + "\n")
                if item.get("type") == "frame":
                    with open(STATE, "w", encoding="utf-8") as sf:
                        json.dump(item, sf, indent=2)

    def _handle_snapshot(self, body):
        data = json.loads(body)
        png_b64 = data.get("png", "")
        if "," in png_b64:  # strip data:image/png;base64, prefix
            png_b64 = png_b64.split(",", 1)[1]
        name = data.get("name") or f"snap-{_now_ms()}.png"
        path = os.path.join(SNAP_DIR, name)
        with open(path, "wb") as f:
            f.write(base64.b64decode(png_b64))
        with open(os.path.join(SNAP_DIR, "latest.txt"), "w") as f:
            f.write(name)
        meta = data.get("meta")
        if meta is not None:
            with open(os.path.join(SNAP_DIR, name + ".json"), "w", encoding="utf-8") as f:
                json.dump(meta, f, indent=2)
        # also drop a marker in the event stream
        with open(EVENTS, "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": _now_ms(), "type": "snapshot", "name": name}) + "\n")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8181
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"chessdebug collector listening on http://127.0.0.1:{port}")
    print(f"writing to {HERE}")
    srv.serve_forever()


if __name__ == "__main__":
    main()
