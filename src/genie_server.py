#!/usr/bin/env python3
"""Thin HTTP wrapper around Qualcomm Genie (genie-t2t-run) for NPU LLM inference.

Exposes an Ollama-compatible /api/generate endpoint so assistant.py can use
the Hexagon NPU without code changes — just point OLLAMA_URL at this server.

Runs as a systemd service on the Radxa Dragon Q6A (QCS6490).
"""

import json
import os
import re
import subprocess
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

# --- Config ---
GENIE_DIR = os.getenv("GENIE_DIR", os.path.expanduser("~/Llama3.2-1B-1024-v68"))
GENIE_BIN = os.path.join(GENIE_DIR, "genie-t2t-run")
GENIE_CONFIG = os.path.join(GENIE_DIR, "htp-model-config-llama32-1b-gqa.json")
HOST = os.getenv("GENIE_HOST", "127.0.0.1")
PORT = int(os.getenv("GENIE_PORT", "11434"))


def build_prompt(system: str, user_prompt: str) -> str:
    """Format system + user text into Llama 3.2 chat template."""
    parts = ["<|begin_of_text|>"]
    if system:
        parts.append(
            f"<|start_header_id|>system<|end_header_id|>\n\n{system}<|eot_id|>"
        )
    parts.append(
        f"<|start_header_id|>user<|end_header_id|>\n\n{user_prompt}<|eot_id|>"
    )
    parts.append("<|start_header_id|>assistant<|end_header_id|>\n\n")
    return "".join(parts)


def run_genie(prompt: str, num_predict: int = 200) -> tuple[str, float]:
    """Run genie-t2t-run and return (response_text, duration_seconds)."""
    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = GENIE_DIR

    start = time.monotonic()
    result = subprocess.run(
        [GENIE_BIN, "-c", GENIE_CONFIG, "-p", prompt],
        capture_output=True, text=True, timeout=60,
        cwd=GENIE_DIR, env=env,
    )
    duration = time.monotonic() - start

    output = result.stdout + result.stderr
    # Extract text between [BEGIN]: and [END]
    match = re.search(r"\[BEGIN\]:\s*(.*?)\[END\]", output, re.DOTALL)
    if match:
        text = match.group(1).strip()
    else:
        # Fallback: return everything after [BEGIN]: if [END] is missing
        match = re.search(r"\[BEGIN\]:\s*(.*)", output, re.DOTALL)
        text = match.group(1).strip() if match else ""

    # Truncate at stop tokens that may appear in the output
    for stop in ("<|eot_id|>", "<|end_of_text|>", "<|start_header_id|>"):
        idx = text.find(stop)
        if idx != -1:
            text = text[:idx].strip()

    return text, duration


class GenieHandler(BaseHTTPRequestHandler):
    """Handle Ollama-compatible /api/generate requests."""

    def do_POST(self):
        if self.path == "/api/generate":
            self._handle_generate()
        else:
            self.send_error(404)

    def do_GET(self):
        # Health check — Ollama returns 200 on GET /
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok"}).encode())
        else:
            self.send_error(404)

    def _handle_generate(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length)) if length else {}

        system = body.get("system", "")
        user_prompt = body.get("prompt", "")
        if not user_prompt:
            self.send_error(400, "missing prompt")
            return

        prompt = build_prompt(system, user_prompt)
        response_text, duration = run_genie(prompt)

        reply = {
            "model": "llama3.2:1b-npu",
            "response": response_text or "Sorry, I didn't get a response.",
            "done": True,
            "total_duration": int(duration * 1e9),
        }
        payload = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        print(f"[genie-server] {args[0]}")


class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


def main():
    # Verify genie binary exists
    if not os.path.isfile(GENIE_BIN):
        print(f"ERROR: genie-t2t-run not found at {GENIE_BIN}")
        raise SystemExit(1)

    # Start server first so it's reachable during warmup
    server = ReusableHTTPServer((HOST, PORT), GenieHandler)
    print(f"Genie NPU server listening on {HOST}:{PORT}")

    # Warm up — load model once so subsequent calls are faster (OS page cache)
    print(f"Warming up NPU model from {GENIE_DIR} ...")
    try:
        text, dur = run_genie(build_prompt("Reply with one word.", "hi"))
        print(f"  Warmup done in {dur:.1f}s: {text!r}")
    except Exception as e:
        print(f"  Warmup failed (will load on first query): {e}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()
    print("Server stopped.")


if __name__ == "__main__":
    main()
