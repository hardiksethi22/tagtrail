import json
import threading

from worker.errors import WorkerError

PROTOCOL_VERSION = 1
MAX_LINE_BYTES = 1024 * 1024
MAX_CREDENTIAL_BYTES = 512 * 1024
COMMANDS = {"doctor", "authenticate", "list_devices", "poll"}


def decode_request(line):
    try:
        if len(line) > MAX_LINE_BYTES or not line.endswith(b"\n"):
            raise ValueError()
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError()
                result[key] = value
            return result
        request = json.loads(line.decode("utf-8"), object_pairs_hook=unique,
                             parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if not isinstance(request, dict):
            raise ValueError()
        allowed = {"protocol_version", "request_id", "command", "timeout_ms",
                   "credential_bundle", "device_id", "browser_helper"}
        if set(request) - allowed:
            raise ValueError()
        if type(request["protocol_version"]) is not int or request["protocol_version"] != 1:
            raise ValueError()
        if not isinstance(request["request_id"], str) or not 1 <= len(request["request_id"]) <= 128:
            raise ValueError()
        if request["command"] not in COMMANDS:
            raise ValueError()
        if type(request["timeout_ms"]) is not int or not 0 < request["timeout_ms"] <= 300_000:
            raise ValueError()
        if request["command"] == "poll" and (
            not isinstance(request.get("device_id"), str) or
            not 1 <= len(request["device_id"]) <= 1024
        ):
            raise ValueError()
        if "credential_bundle" in request:
            bundle = request["credential_bundle"]
            if not isinstance(bundle, dict) or len(json.dumps(bundle).encode()) > MAX_CREDENTIAL_BYTES:
                raise ValueError()
        if "browser_helper" in request:
            if request["command"] != "authenticate" or not isinstance(request["browser_helper"], dict):
                raise ValueError()
            config = request["browser_helper"]
            if set(config) - {"enabled", "chromedriver_path", "artifact_directory", "chrome_binary"}:
                raise ValueError()
            if type(config.get("enabled")) is not bool:
                raise ValueError()
            if any(not isinstance(config[key], str) or not config[key]
                   for key in ("chromedriver_path", "artifact_directory", "chrome_binary")
                   if key in config):
                raise ValueError()
        return request
    except (KeyError, ValueError, TypeError, UnicodeError, RecursionError):
        raise WorkerError("protocol-error") from None


class Emitter:
    def __init__(self, output, request_id):
        self.output = output
        self.request_id = request_id
        self.terminal = False
        self.lock = threading.Lock()
        self.total = 0

    def emit(self, event, payload=None, **fields):
        with self.lock:
            if self.terminal:
                return
            message = dict(protocol_version=1, request_id=self.request_id, event=event)
            if payload is not None:
                message["payload"] = payload
            message.update(fields)
            encoded = json.dumps(message, ensure_ascii=False, allow_nan=False,
                                 separators=(",", ":")) + "\n"
            size = len(encoded.encode())
            budget = 8 * MAX_LINE_BYTES - (0 if event in {"result", "error"} else 1024)
            if size > MAX_LINE_BYTES or self.total + size > budget:
                raise WorkerError("protocol-error")
            self.output.write(encoded)
            self.output.flush()
            self.total += size
            if event in {"result", "error"}:
                self.terminal = True
