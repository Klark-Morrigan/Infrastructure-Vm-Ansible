#!/usr/bin/env python3
"""Mock GitHub API server for the runner_registration molecule scenario.

The role's existence-probe and token-mint tasks all hit endpoints under
/repos/<owner>/<repo>/actions/runners. This server returns canned
responses for the three the role uses, records every request as a
JSON line to a log the verify play parses, and reads the set of
"registered" runners from a file it re-reads on every GET so the
side_effect play can mutate the GitHub-side state between the converge
and idempotence runs (real GitHub remembers a successful registration;
a static mock cannot, so we make the mock dynamic via the file).

The server binds 127.0.0.1 by design: the role's delegate_to: localhost
puts the request on the controller, where the mock also lives, so
loopback is the only address that needs to work.
"""

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer


class MockHandler(BaseHTTPRequestHandler):
    """Per-request handler. Class attributes carry config so the
    handler does not need a custom __init__ (the http.server framework
    instantiates the class per request)."""

    log_path = None
    registered_path = None

    def log_message(self, fmt, *args):
        # Silence the default stderr access log so molecule's prepare
        # output stays clean; the JSON-lines log is the assertion
        # surface for the verify play.
        return

    def _registered(self):
        """Read the registered-runners file fresh on every call.

        Re-reading per request is what lets side_effect.yml mutate the
        file between converge and idempotence without restarting the
        server. Returns an empty list when the file is missing - this
        is the "nothing registered yet" case prepare deliberately
        leaves the file in for the fresh / re-register entries.
        """
        if not MockHandler.registered_path:
            return []
        try:
            with open(MockHandler.registered_path, "r", encoding="utf-8") as fh:
                return [line.strip() for line in fh if line.strip()]
        except FileNotFoundError:
            return []

    def _record(self):
        """Append one JSON line per request to the log.

        Path and method are the only fields the verify play asserts on;
        the Authorization header is intentionally NOT recorded so a
        test bug that leaked a token into argv cannot also leak it via
        this log.
        """
        rec = {"method": self.command, "path": self.path}
        with open(MockHandler.log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._record()
        # GET /repos/<owner>/<repo>/actions/runners[?per_page=...]
        # is the only GET the role makes. Anything else is a test bug
        # we want to surface as a 404 rather than silently 200.
        path = self.path.split("?", 1)[0]
        if path.endswith("/actions/runners"):
            registered = self._registered()
            runners = [
                {"name": name, "id": idx + 1, "status": "online"}
                for idx, name in enumerate(registered)
            ]
            self._send_json(200, {"total_count": len(runners), "runners": runners})
            return
        self._send_json(404, {"message": "not found"})

    def do_POST(self):
        # Consume the body so the framework does not complain on
        # connection close. The role's token mints send a 0-length
        # body, but reading defensively is cheaper than debugging a
        # broken pipe later.
        try:
            body_len = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            body_len = 0
        if body_len:
            self.rfile.read(body_len)
        self._record()
        # Both token endpoints return 201 with a token string and an
        # expires_at ISO timestamp, matching the real GitHub contract
        # closely enough that the role's status_code: 201 guard fires
        # on a regression rather than a fixture skew.
        expires_at = (
            datetime.now(timezone.utc) + timedelta(hours=1)
        ).isoformat()
        path = self.path
        if path.endswith("/actions/runners/registration-token"):
            self._send_json(
                201,
                {"token": "FAKE_REGISTRATION_TOKEN", "expires_at": expires_at},
            )
            return
        if path.endswith("/actions/runners/remove-token"):
            self._send_json(
                201,
                {"token": "FAKE_REMOVAL_TOKEN", "expires_at": expires_at},
            )
            return
        self._send_json(404, {"message": "not found"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument(
        "--log",
        required=True,
        help="JSON-lines file to append every request to (truncated on start).",
    )
    parser.add_argument(
        "--registered-file",
        required=True,
        help=(
            "Text file with one already-registered runner name per line. "
            "Re-read on every GET so side_effect.yml can mutate state."
        ),
    )
    args = parser.parse_args()

    MockHandler.log_path = args.log
    MockHandler.registered_path = args.registered_file
    # Truncate the log so each test sequence starts from a clean
    # surface; the verify play assumes the log only contains requests
    # made during this scenario.
    open(args.log, "w", encoding="utf-8").close()

    server = HTTPServer(("127.0.0.1", args.port), MockHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
