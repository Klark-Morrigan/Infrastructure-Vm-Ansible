#!/usr/bin/env python3
"""Mock GitHub Actions runners API for every runner-side test.

Single source for both directions of the GitHub Actions runners
contract this repo exercises:

    GET    /repos/<owner>/<repo>/actions/runners                   existence probe
    POST   /repos/<owner>/<repo>/actions/runners/registration-token register mint
    POST   /repos/<owner>/<repo>/actions/runners/remove-token       remove mint
    DELETE /repos/<owner>/<repo>/actions/runners/<id>               force path

Callers:

    Tests/molecule/runner_registration/default + remove
        Exercises GET + the POST mints (register / re-register / remove
        flows on the per-VM path).

    Tests/ansible/test-deregister-runners-playbook.yml
        Exercises GET + DELETE (controller-side --force fan-out for
        unreachable VMs).

Two mocks would each pull in the same MockHandler / _registered /
_send_json / log_message / argparse boilerplate, so consolidating
trades one shared maintenance surface for the contract drift risk
two would carry. Neither caller is broken by the verbs it does not
exercise; each just never hits the unused branches.

Logging contract:

    Each request appends one JSON line to the configured `--log` file
    with `method` and `path`. DELETE additionally records the
    `runner_id` captured from the URL so the deregister smoke playbook
    can assert which runner the force path targeted. The
    `Authorization` header is intentionally NOT recorded so a future
    regression that leaks a token into argv cannot also leak it via
    this log.

Bind address:

    127.0.0.1 only. Both callers run the GitHub-side tasks on the
    controller (the role's `delegate_to: localhost`; the smoke
    playbook's `hosts: localhost`), so loopback is the only address
    that has to work, and binding wider would invite a stray hit
    from another process on the host.
"""

import argparse
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer


# /repos/<owner>/<repo>/actions/runners/<id> with an optional query
# string. Match group `runner_id` becomes a log field so the smoke
# playbook can assert the force path targeted the right runner.
_DELETE_PATH_RE = re.compile(
    r"^/repos/[^/]+/[^/]+/actions/runners/(?P<runner_id>\d+)(?:\?.*)?$"
)


class MockHandler(BaseHTTPRequestHandler):
    """Per-request handler. Class attributes carry config because the
    http.server framework instantiates the handler class per request
    and offers no init hook for shared state."""

    log_path = None
    registered_path = None

    def log_message(self, fmt, *args):
        # Silence the default stderr access log: both callers parse
        # the JSON-lines log instead, and a quiet stderr keeps the
        # molecule prepare and the smoke-test stdout legible.
        return

    def _registered(self):
        """Read the registered-runners file fresh on every call.

        Re-reading per request lets callers mutate state between
        phases without restarting the server (molecule's
        side_effect.yml clears the file between converge and
        idempotence; the deregister smoke playbook keeps the file
        stable across both modes). Missing file means nothing
        registered yet.
        """
        if not MockHandler.registered_path:
            return []
        try:
            with open(MockHandler.registered_path, "r", encoding="utf-8") as fh:
                return [line.strip() for line in fh if line.strip()]
        except FileNotFoundError:
            return []

    def _record(self, extra=None):
        """Append one JSON line per request to the log.

        `extra` is the per-verb hook (DELETE adds the captured
        runner_id). The Authorization header is deliberately not
        recorded — see the module docstring.
        """
        rec = {"method": self.command, "path": self.path}
        if extra:
            rec.update(extra)
        with open(MockHandler.log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._record()
        # GET /repos/<owner>/<repo>/actions/runners[?per_page=...] is
        # the only GET either caller makes; anything else is a test
        # bug worth surfacing as a 404 instead of a silent 200.
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
        # Drain the body so the framework does not complain on
        # connection close. Both token mints send a 0-length body in
        # practice but reading defensively beats debugging a broken
        # pipe later.
        try:
            body_len = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError:
            body_len = 0
        if body_len:
            self.rfile.read(body_len)
        self._record()
        # Both token endpoints return 201 with a token string and an
        # ISO `expires_at`, matching the real GitHub contract closely
        # enough that the role's `status_code: 201` guard fires on a
        # genuine regression rather than a fixture skew.
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

    def do_DELETE(self):
        # GitHub returns 204 No Content on a successful runner delete,
        # so the mock matches the contract the role asserts via
        # `status_code: [200, 204, 404]`.
        match = _DELETE_PATH_RE.match(self.path)
        if match:
            self._record(extra={"runner_id": match.group("runner_id")})
            self._send_empty(204)
            return
        self._record()
        self._send_json(404, {"message": "not found"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument(
        "--log",
        required=True,
        help=(
            "JSON-lines file to append every request to. Truncated on "
            "start so each test sequence asserts against a clean log."
        ),
    )
    parser.add_argument(
        "--registered-file",
        required=True,
        help=(
            "Text file with one already-registered runner name per "
            "line. Re-read on every GET so callers can mutate state "
            "without restarting the server."
        ),
    )
    args = parser.parse_args()

    MockHandler.log_path = args.log
    MockHandler.registered_path = args.registered_file
    open(args.log, "w", encoding="utf-8").close()

    server = HTTPServer(("127.0.0.1", args.port), MockHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
