import contextlib
import io
import json
import logging
import signal
import sys
import time

from worker.errors import WorkerError
from worker.protocol import MAX_LINE_BYTES, Emitter, decode_request


class DiagnosticSink(io.TextIOBase):
    """Discard third-party diagnostics, not heuristically redact secrets."""
    def write(self, text):
        return len(text)

    def flush(self):
        pass


def classify(exc):
    if isinstance(exc, WorkerError):
        return exc
    import requests
    import httpx
    import aiohttp
    from google.protobuf.message import DecodeError
    from selenium.common.exceptions import TimeoutException, WebDriverException
    if isinstance(exc, (requests.Timeout, httpx.TimeoutException, TimeoutError, TimeoutException)):
        return WorkerError("timeout")
    if isinstance(exc, WebDriverException):
        return WorkerError("authentication-required")
    if isinstance(exc, (requests.RequestException, httpx.RequestError,
                        aiohttp.ClientError, ConnectionError, OSError)):
        return WorkerError("network-unavailable")
    if isinstance(exc, DecodeError):
        return WorkerError("protocol-error")
    return WorkerError("internal-error")


def main():
    stdout, stderr = sys.stdout, sys.stderr
    # Keep late third-party background callbacks off the protocol descriptors.
    sys.stdout, sys.stderr = DiagnosticSink(), DiagnosticSink()
    emitter = Emitter(stdout, "invalid")
    adapter = None
    logging.disable(logging.CRITICAL)
    def deadline_expired(signum, frame):
        raise WorkerError("timeout")
    signal.signal(signal.SIGALRM, deadline_expired)
    signal.signal(signal.SIGTERM, deadline_expired)
    signal.signal(signal.SIGINT, deadline_expired)
    signal.setitimer(signal.ITIMER_REAL, 5)
    try:
        line = sys.stdin.buffer.readline(MAX_LINE_BYTES + 1)
        # Preserve a valid correlation ID even when other fields are invalid.
        try:
            raw = json.loads(line)
            if isinstance(raw, dict) and isinstance(raw.get("request_id"), str) and 1 <= len(raw["request_id"]) <= 128:
                emitter.request_id = raw["request_id"]
        except (ValueError, UnicodeError, RecursionError):
            pass
        request = decode_request(line)
        emitter.request_id = request["request_id"]
        limit = 300 if request["command"] == "authenticate" else 45
        timeout = min(request["timeout_ms"] / 1000, limit)
        deadline = time.monotonic() + timeout
        signal.setitimer(signal.ITIMER_REAL, timeout)
        emitter.emit("ready", payload={"worker": "TagTrailWorker"})
        with contextlib.redirect_stdout(DiagnosticSink()), contextlib.redirect_stderr(DiagnosticSink()):
            from worker.adapter import GoogleAdapter
            adapter = GoogleAdapter(request, emitter.emit, deadline)
            result = adapter.execute()
            adapter.close()
            adapter = None
        signal.setitimer(signal.ITIMER_REAL, 0)
        emitter.emit("result", payload=result)
        return 0
    except BaseException as exc:
        signal.setitimer(signal.ITIMER_REAL, 0)
        with contextlib.redirect_stdout(DiagnosticSink()), contextlib.redirect_stderr(DiagnosticSink()):
            if adapter:
                try:
                    adapter.close()
                except BaseException:
                    pass
                adapter = None
            try:
                error = classify(exc)
            except Exception:
                error = WorkerError("internal-error")
        fields = {"code": error.code}
        if error.retry_after_ms is not None:
            fields["retry_after_ms"] = error.retry_after_ms
        emitter.emit("error", **fields)
        stderr.write("TagTrailWorker: " + error.code + "\n")
        stderr.flush()
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        if adapter:
            with contextlib.redirect_stdout(DiagnosticSink()), contextlib.redirect_stderr(DiagnosticSink()):
                try:
                    adapter.close()
                except BaseException:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
