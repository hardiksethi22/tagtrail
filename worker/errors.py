ERROR_CODES = frozenset({
    "authentication-required", "credentials-locked", "unsupported-device",
    "rate-limited", "network-unavailable", "timeout", "protocol-error",
    "decryption-error", "internal-error",
})


class WorkerError(Exception):
    def __init__(self, code, retry_after_ms=None):
        if code not in ERROR_CODES:
            raise ValueError("Unknown error category")
        super().__init__(code)
        self.code = code
        self.retry_after_ms = retry_after_ms
