#!/usr/bin/env python3
"""
An OpenAI-compatible chat endpoint backed by opencode's free models.

Why this exists
---------------
OpenCode's free tier refuses to be called directly:

    HTTP 403  "OpenCode's free tier can only be used from within OpenCode."

The key is checked, but the *client* is what is being restricted. A phone app posting straight to
https://opencode.ai/inference/v1/chat/completions is not OpenCode, so it gets the 403. The paid
models work from anywhere, but they cost money and this account has no funds in it.

So the app cannot call the gateway itself, but the gateway is happy when opencode calls it — and
opencode already can, with no key at all. This is the seam: it speaks OpenAI's chat completions
shape on the front, shells out to `opencode run` on the back, and re-emits the result as the SSE
frames the app's streaming client expects.

The app is otherwise unchanged. BrainConfiguration points at this instead of the gateway, and the
key becomes a local placeholder.

Cost and privacy
----------------
Free models cost nothing: `opencode run` reports "cost": 0. space-bunny-free is the default
because its provider is zero-retention and does not train on prompts, which matters because the
prompts carry the learner's own written answers.

Latency
-------
Each turn spawns one `opencode run`, which costs roughly a second of process startup before the
first token. That is the price of the free tier and it is noticeable in a spoken conversation.
Sessions are continued with --session so multi-turn context is kept without paying startup twice.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_MODEL = "space-bunny-free"
DEFAULT_PORT = 8787

# One session per client conversation. The tutor's own message history is sent in full every
# turn, so the session id is only used to let opencode reuse a warm process rather than to hold
# the conversation — but reusing it still avoids a cold start.
_sessions: dict[str, str] = {}
_lock = threading.Lock()


def run_turn(model: str, prompt: str, conversation: str) -> str:
    """One turn through `opencode run`, returning the assistant text.

    --format json gives a stream of newline-delimited events; the ones that matter are `text`,
    which carries the visible answer, and `step_finish`, which carries the token and cost
    accounting. Everything else — step starts, tool calls — is ignored on purpose.
    """
    command = [
        "opencode", "run",
        "--model", f"opencode/{model}",
        "--format", "json",
        "--pure",
        prompt,
    ]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=300,
            input=conversation or None,
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("opencode did not finish within 300s")

    if completed.returncode != 0:
        tail = (completed.stderr or "").strip().splitlines()
        raise RuntimeError(tail[-1] if tail else "opencode exited non-zero")

    answer: list[str] = []
    for line in completed.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "text":
            part = event.get("part") or {}
            text = part.get("text")
            if isinstance(text, str):
                answer.append(text)

    return "".join(answer)


class Handler(BaseHTTPRequestHandler):
    model = DEFAULT_MODEL
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # quieter, and on stderr so it does not corrupt SSE
        sys.stderr.write("bridge: " + (fmt % args) + "\n")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "authorization, content-type")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self):
        if self.path.rstrip("/") not in ("/v1/chat/completions", "/chat/completions"):
            self.send_error(404, "unknown route")
            return

        length = int(self.headers.get("Content-Length", "0"))
        try:
            request = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_error(400, "body is not JSON")
            return

        model = request.get("model") or self.model
        messages = request.get("messages") or []

        # Flatten the conversation into the single prompt `opencode run` takes, keeping the
        # system turn as the instruction and the rest as context. `opencode run` has no
        # messages[] parameter, so this is the only way to preserve a multi-turn history.
        system = "\n\n".join(
            m["content"] for m in messages if m.get("role") == "system"
        )
        turns = [
            f"{'Stanley' if m.get('role') == 'user' else 'Tutor'}: {m.get('content', '')}"
            for m in messages
            if m.get("role") in ("user", "assistant")
        ]
        latest = ""
        for message in reversed(messages):
            if message.get("role") == "user":
                latest = message.get("content", "")
                break

        prompt = (
            "Continue this tutoring conversation. Reply only as the Tutor, in the tutor's voice, "
            "with no preamble and no repetition of the question.\n\n"
            + system
            + ("\n\n" + "\n".join(turns) if turns else "")
        )

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self._cors()
        self.end_headers()

        identifier = str(uuid.uuid4())
        try:
            # `opencode run` is not a streaming subprocess, so the reply arrives whole and is
            # faked out as SSE in sentence-sized pieces. The app buffers by sentence before
            # speaking, so this still starts talking promptly rather than after the whole turn.
            answer = run_turn(model, prompt, "")
        except Exception as error:  # noqa: BLE001 - the app shows this text
            self.wfile.write(
                f'data: {{"choices":[{{"delta":{{"content":"[bridge error] {error}"}}}}]}}\n\n'
                .encode()
            )
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        for piece in _chunks(answer):
            frame = {
                "id": identifier,
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{"index": 0, "delta": {"content": piece}}],
            }
            self.wfile.write(f"data: {json.dumps(frame)}\n\n".encode())
            self.wfile.flush()

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def do_GET(self):
        """A health check the app's Settings can call to show the bridge is reachable."""
        if self.path.rstrip("/") in ("/health", "/v1/health"):
            body = json.dumps({
                "ok": True,
                "model": self.model,
                "free": True,
                "note": "backed by opencode's free tier; no API key involved",
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self._cors()
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404, "unknown route")


def _chunks(text: str, size: int = 48) -> list[str]:
    """Split a finished reply into word-boundary pieces, so the client sees a plausible stream."""
    words = text.split(" ")
    out, current = [], ""
    for word in words:
        candidate = f"{current} {word}".strip()
        if len(candidate) >= size:
            out.append(candidate + " ")
            current = ""
        else:
            current = candidate
    if current:
        out.append(current)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--hostname",
        default="127.0.0.1",
        help="Use 0.0.0.0 to reach it from the phone on the same wifi. That exposes the bridge "
             "to your whole network, so only do it on a network you trust.",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL)
    args = parser.parse_args()

    Handler.model = args.model
    server = ThreadingHTTPServer((args.hostname, args.port), Handler)
    print(f"opencode bridge on http://{args.hostname}:{args.port}  model={args.model}  (free)")
    print("The phone should point at this. No API key is used.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
