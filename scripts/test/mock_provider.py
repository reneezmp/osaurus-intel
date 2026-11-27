#!/usr/bin/env python3
"""Local fake OpenAI-compatible provider for testing the Intel dev build.
Listens on 127.0.0.1 only. The reply depends on a keyword in the latest user
message. Keywords: WRITE TWO, CONFIG PLAN, ANNOUNCE, SLOW, MIDERROR, TRUNCATE.
Every request body is appended to $MOCK_LOG (default
/tmp/osaurus-gate/mock-requests.jsonl); headers are never logged.
Run: /usr/bin/python3 -I scripts/test/mock_provider.py, then add a custom
provider HTTP 127.0.0.1:8765 /v1, no auth, in the dev app."""
import json, os, sys, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ.get("MOCK_LOG", "/tmp/osaurus-gate/mock-requests.jsonl")
os.makedirs(os.path.dirname(LOG), exist_ok=True)
MODEL = "mock-model"


def last_user(msgs):
    for m in reversed(msgs):
        if m.get("role") == "user":
            c = m.get("content")
            if isinstance(c, list):
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            return c or ""
    return ""


def chunk(delta, finish=None, usage=None):
    d = {"id": "chatcmpl-mock", "object": "chat.completion.chunk", "created": int(time.time()),
         "model": MODEL, "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
    if usage:
        d["usage"] = usage
    return d


def tool_call(idx, name, args):
    return {"index": idx, "id": "call_%s" % uuid.uuid4().hex[:12], "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)}}


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        sys.stderr.write("mock: " + (fmt % a) + "\n")

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path.rstrip("/").endswith("models"):
            return self._json(200, {"object": "list", "data": [{"id": MODEL, "object": "model", "owned_by": "mock"}]})
        self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "body": body}) + "\n")
        if not self.path.rstrip("/").endswith("chat/completions"):
            return self._json(404, {"error": {"message": "not found"}})
        msgs = body.get("messages", [])
        text = last_user(msgs)
        tools = [t.get("function", {}).get("name") for t in body.get("tools", []) or []]
        tool_results = [m for m in msgs if m.get("role") == "tool"]
        stream = body.get("stream", False)
        usage = {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18}

        if not stream:
            return self._json(200, {"id": "x", "object": "chat.completion", "model": MODEL,
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant", "content": "Mock title"}}], "usage": usage})

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def send(d):
            self.wfile.write(b"data: " + json.dumps(d).encode() + b"\n\n")
            self.wfile.flush()

        def say(s, delay=0.02):
            for w in s.split(" "):
                send(chunk({"content": w + " "}))
                time.sleep(delay)

        def done(finish="stop"):
            send(chunk({}, finish, usage))
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()

        try:
            key = text.upper()
            if "WRITE TWO" in key and not tool_results:
                send(chunk({"role": "assistant", "tool_calls": [
                    tool_call(0, "file_write", {"path": "mock_a.txt", "content": "A"}),
                    tool_call(1, "file_write", {"path": "mock_b.txt", "content": "B"})]}))
                return done("tool_calls")
            if "CONFIG PLAN" in key and not tool_results:
                send(chunk({"role": "assistant", "tool_calls": [tool_call(0, "osaurus_config", {
                    "action": "apply",
                    "yaml": "version: 1\ndelegation:\n  budget_max_tokens: 2048\n"})]}))
                return done("tool_calls")
            if "ANNOUNCE" in key and len([m for m in msgs if m.get("role") == "assistant"]) == 0:
                say("Let me write the file:")
                return done("stop")
            if "SLOW" in key:
                for i in range(200):
                    send(chunk({"content": "word%d " % i}))
                    time.sleep(0.25)
                return done()
            if "MIDERROR" in key:
                say("Partial answer before the provider fails.")
                send({"error": {"message": "mock provider exploded mid-stream", "code": "mock_error"}})
                return
            if "TRUNCATE" in key:
                say("This answer is cut off because")
                return done("length")
            if tool_results:
                say("Done. Tool results received: %d." % len(tool_results))
                return done()
            say("Mock reply. Tools offered: %d. Names: %s" % (len(tools), ", ".join(sorted(tools)[:12])))
            return done()
        except (BrokenPipeError, ConnectionResetError):
            sys.stderr.write("mock: client closed the stream\n")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8765), H).serve_forever()
