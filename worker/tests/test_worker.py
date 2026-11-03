import asyncio
import base64
import io
import json
import signal
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch, Mock

from worker.adapter import (FCMTransport, GoogleAdapter, check_http, load_upstream,
                            normalize_update, validate_bundle)
from worker.errors import ERROR_CODES, WorkerError
from worker.protocol import decode_request, Emitter, MAX_LINE_BYTES
from worker.tests.fixtures import bundle, device_list, update, OWNER, SECRET

ROOT = Path(__file__).resolve().parents[2]


def request(command="doctor", **kwargs):
    result = dict(protocol_version=1, request_id="synthetic-request", command=command,
                  timeout_ms=10000)
    result.update(kwargs)
    return result


class ProtocolTests(unittest.TestCase):
    def test_shared_protocol_v1_fixtures(self):
        examples = json.loads((ROOT / "worker/fixtures/protocol-v1.json").read_text())
        self.assertEqual(examples["protocol_version"], 1)
        for example in examples["request_examples"]:
            self.assertEqual(decode_request((json.dumps(example) + "\n").encode()), example)
        for example in examples["event_examples"]:
            output = io.StringIO()
            emitter = Emitter(output, example["request_id"])
            fields = {key: value for key, value in example.items()
                      if key not in {"protocol_version", "request_id", "event"}}
            emitter.emit(example["event"], **fields)
            self.assertEqual(json.loads(output.getvalue()), example)
        fixture = json.loads((ROOT / "AppTests/protocol-v1.json").read_text())
        request_example = fixture["request"]
        self.assertEqual(decode_request((json.dumps(request_example) + "\n").encode()), request_example)
        output = io.StringIO()
        emitter = Emitter(output, request_example["request_id"])
        for example in fixture["success_events"]:
            fields = {key: value for key, value in example.items()
                      if key not in {"protocol_version", "request_id", "event"}}
            emitter.emit(example["event"], **fields)
        self.assertEqual([json.loads(line) for line in output.getvalue().splitlines()],
                         fixture["success_events"])
        self.assertTrue(emitter.terminal)
        error = fixture["error_event"]
        output = io.StringIO()
        emitter = Emitter(output, request_example["request_id"])
        emitter.emit("error", code=error["code"], retry_after_ms=error["retry_after_ms"])
        self.assertEqual(json.loads(output.getvalue()), error)
        self.assertIn(error["code"], ERROR_CODES)

    def run_worker(self, data):
        return subprocess.run([sys.executable, "-m", "worker"], input=data,
                              cwd=ROOT, capture_output=True, timeout=15)

    def test_doctor_actual_transport(self):
        result = self.run_worker((json.dumps(request()) + "\n").encode())
        self.assertEqual(result.returncode, 0, result.stderr)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(events[0]["event"], "ready")
        self.assertEqual(events[-1]["event"], "result")
        self.assertEqual(events[-1]["payload"]["status"], "ok")
        self.assertEqual(events[-1]["payload"]["upstream_commit"],
                         "660be5395702ff7f1a6174f4ec4c865a57c7b527")

    def test_split_utf8_input(self):
        process = subprocess.Popen([sys.executable, "-m", "worker"], cwd=ROOT,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        data = (json.dumps(request(request_id="Unicode合成"), ensure_ascii=False) + "\n").encode()
        for byte in data:
            process.stdin.write(bytes([byte]))
            process.stdin.flush()
        process.stdin.close()
        process.stdin = None
        stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(json.loads(stdout.splitlines()[-1])["request_id"], "Unicode合成")

    def test_invalid_and_eof_one_terminal_redacted(self):
        cases = [b"", b"{malformed\n", b'{"protocol_version":2,"request_id":"id"}\n',
                 b"x" * (MAX_LINE_BYTES + 1) + b"\n",
                 (json.dumps(request(command="authenticate",
                                     credential_bundle={"username": SECRET, "aas_token": SECRET})) + "\n").encode()]
        for data in cases:
            with self.subTest(size=len(data)):
                result = self.run_worker(data)
                events = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(sum(e["event"] in {"result", "error"} for e in events), 1)
                self.assertEqual(events[-1]["event"], "error")
                self.assertNotIn(SECRET.encode(), result.stdout + result.stderr)
                self.assertNotIn(b"Traceback", result.stderr)

    def test_protocol_rejects_duplicates_boolean_nan_unknown(self):
        for change in [dict(protocol_version=True), dict(timeout_ms=True),
                       dict(timeout_ms=0), dict(extra="x")]:
            candidate = request()
            candidate.update(change)
            with self.assertRaises(WorkerError):
                decode_request((json.dumps(candidate) + "\n").encode())
        with self.assertRaises(WorkerError):
            decode_request(b'{"request_id":"a","request_id":"b"}\n')
        with self.assertRaises(WorkerError):
            decode_request(b'{"protocol_version":NaN}\n')

    def test_actual_request_deadline_and_sigterm_cleanup(self):
        script = """
import time
from worker.adapter import GoogleAdapter
from worker.__main__ import main
GoogleAdapter.execute = lambda self: time.sleep(20)
GoogleAdapter.close = lambda self: self.emit('progress', payload={'stage':'cleaned-up'})
raise SystemExit(main())
"""
        short = request(timeout_ms=100)
        started = time.monotonic()
        result = subprocess.run([sys.executable, "-c", script], cwd=ROOT,
                                input=(json.dumps(short) + "\n").encode(),
                                capture_output=True, timeout=5)
        self.assertLess(time.monotonic() - started, 3)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(events[-1]["code"], "timeout")
        self.assertEqual(events[-2]["payload"]["stage"], "cleaned-up")
        process = subprocess.Popen([sys.executable, "-c", script], cwd=ROOT,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE)
        try:
            process.stdin.write((json.dumps(request()) + "\n").encode())
            process.stdin.flush()
            first = json.loads(process.stdout.readline())
            self.assertEqual(first["event"], "ready")
            time.sleep(0.1)
            process.send_signal(signal.SIGTERM)
            process.stdin.close()
            process.stdin = None
            output, stderr = process.communicate(timeout=5)
            self.assertNotEqual(process.returncode, 0)
            self.assertEqual(json.loads(output.splitlines()[-1])["code"], "timeout")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)

    def test_large_third_party_diagnostics_never_escape(self):
        script = """
import sys
from worker.adapter import GoogleAdapter
from worker.__main__ import main
def execute(self):
    print('PLANTED_SECRET_DO_NOT_LOG' * 100000, file=sys.stderr)
    print('PLANTED_SECRET_DO_NOT_LOG' * 100000)
    return {'status':'ok'}
GoogleAdapter.execute = execute
raise SystemExit(main())
"""
        result = subprocess.run([sys.executable, "-c", script], cwd=ROOT,
                                input=(json.dumps(request()) + "\n").encode(),
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(SECRET.encode(), result.stdout + result.stderr)
        self.assertEqual(result.stderr, b"")

    def test_runtime_credential_refresh_uses_only_secret_event(self):
        script = """
from worker.adapter import GoogleAdapter
from worker.__main__ import main
def execute(self):
    self.cache.set_cached_value('aas_token','PLANTED_SECRET_DO_NOT_LOG')
    return {'status':'ok'}
GoogleAdapter.execute = execute
raise SystemExit(main())
"""
        result = subprocess.run([sys.executable, "-c", script], cwd=ROOT,
                                input=(json.dumps(request()) + "\n").encode(),
                                capture_output=True, timeout=10)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual([event["event"] for event in events], ["ready", "credential_update", "result"])
        self.assertEqual(events[1]["credential_bundle"]["aas_token"], SECRET)
        self.assertNotIn(SECRET.encode(), result.stderr)

    def test_emitter_credential_update_is_explicit(self):
        output = io.StringIO()
        emitter = Emitter(output, "id")
        emitter.emit("credential_update", credential_bundle=bundle())
        emitter.emit("result", payload={})
        emitter.emit("error", code="internal-error")
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(len(events), 2)
        self.assertEqual(events[0]["credential_bundle"]["aas_token"], SECRET)


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.adapter = GoogleAdapter(request("list_devices", credential_bundle=bundle()),
                                     lambda event, **fields: self.events.append((event, fields)),
                                     time.monotonic() + 10)

    def tearDown(self):
        self.adapter.close()

    def test_cache_never_accesses_plaintext_files(self):
        _, _, cache = load_upstream()
        with patch("builtins.open", side_effect=AssertionError("Disk access forbidden")):
            cache.set_cached_value("owner_key", OWNER.hex())
            self.assertEqual(cache.get_cached_value("owner_key"), OWNER.hex())
            snapshot = cache.memory_snapshot()
            snapshot["aas_token"] = "changed"
            self.assertEqual(cache.get_cached_value("aas_token"), SECRET)
        self.assertEqual(self.events[-1][0], "credential_update")

    def test_import_completeness(self):
        validate_bundle(bundle())
        for path in ("username", "aas_token", "fcm_credentials", "owner_key"):
            candidate = bundle()
            del candidate[path]
            with self.assertRaises(WorkerError):
                validate_bundle(candidate)
        candidate = bundle()
        candidate["fcm_credentials"]["keys"]["private"] = SECRET
        with self.assertRaises(WorkerError):
            validate_bundle(candidate)
        candidate = bundle()
        candidate["fcm_credentials"]["keys"]["public"] = "invalid"
        with self.assertRaises(WorkerError):
            validate_bundle(candidate)

    def test_actual_discovery_request_and_no_tracker_mutation(self):
        import requests
        response = Mock(status_code=200, content=device_list().SerializeToString())
        with patch.object(self.adapter, "oauth", return_value=SECRET), patch.object(requests, "post", return_value=response) as post:
            result = self.adapter.list_devices()
        self.assertEqual(result["devices"], [{"id": "synthetic-tracker", "name": "合成 Tracker", "network": "google"}])
        _, proto, _ = load_upstream()
        query = proto.DevicesListRequest.FromString(post.call_args.kwargs["data"])
        self.assertEqual(query.deviceListRequestPayload.type, proto.SPOT_DEVICE)
        self.assertLessEqual(post.call_args.kwargs["timeout"], 10)

    def test_real_oauth_encoding_session_timeout_and_auth_error(self):
        import gpsoauth
        import requests
        original = gpsoauth._perform_auth_request
        session = Mock()
        session.__enter__ = Mock(return_value=session)
        session.__exit__ = Mock(return_value=False)
        session.post.return_value = Mock(status_code=200, text="Auth=synthetic-scoped-token\n")
        with patch.object(requests, "Session", return_value=session):
            self.assertEqual(self.adapter.oauth(), "synthetic-scoped-token")
        self.assertIs(gpsoauth._perform_auth_request, original)
        self.assertEqual(session.post.call_args.kwargs["data"]["Email"], "planted@example.invalid")
        self.assertGreater(session.post.call_args.kwargs["timeout"], 0)
        session.post.return_value.text = "Error=BadAuthentication\n"
        with patch.object(requests, "Session", return_value=session), self.assertRaises(WorkerError) as caught:
            self.adapter.oauth()
        self.assertEqual(caught.exception.code, "authentication-required")

    def test_real_crypto_formats_semantic_and_zero_coordinate(self):
        for mode in ("gcm", "cbc", "foreign"):
            with self.subTest(mode=mode):
                result = normalize_update(update(mode), "synthetic-tracker", OWNER)
                self.assertEqual(result["rejected_count"], 0)
                self.assertEqual(result["sightings"][0]["latitude"], 0)
                self.assertEqual(result["sightings"][0]["provider_timestamp_ms"], 1732120000123)
                self.assertEqual(result["sightings"][1]["kind"], "semantic")
                self.assertNotIn("latitude", result["sightings"][1])
                self.assertNotIn("report_id", result["sightings"][0])

    def test_corrupt_ciphertext_is_rejected_without_dumping_keys(self):
        fixture = update()
        reports = fixture.deviceMetadata.information.locationInformation.reports.recentLocationAndNetworkLocations
        reports.networkLocations[0].geoLocation.encryptedReport.encryptedLocation = b"corrupt"
        result = normalize_update(fixture, "synthetic-tracker", OWNER)
        self.assertEqual(result["rejected_count"], 1)
        self.assertEqual(len(result["sightings"]), 1)
        del reports.networkLocations[1]
        del reports.networkLocationTimestamps[1]
        with self.assertRaises(WorkerError) as error:
            normalize_update(fixture, "synthetic-tracker", OWNER)
        self.assertEqual(str(error.exception), "decryption-error")

    def test_absent_timestamps_and_empty_results(self):
        fixture = update()
        reports = fixture.deviceMetadata.information.locationInformation.reports.recentLocationAndNetworkLocations
        del reports.networkLocationTimestamps[:]
        result = normalize_update(fixture, "synthetic-tracker", OWNER)
        self.assertEqual(result["sightings"][0]["timestamp_provenance"], "unknown")
        self.assertNotIn("provider_timestamp_ms", result["sightings"][0])
        _, proto, _ = load_upstream()
        self.assertEqual(normalize_update(proto.DeviceUpdate(), "id", OWNER),
                         {"sightings": [], "rejected_count": 0})

    def test_owner_key_real_spot_request_and_refresh(self):
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        import httpx
        from SpotApi.grpc_parser import GrpcParser
        common, proto, cache = load_upstream()
        candidate = bundle()
        del candidate["owner_key"]
        candidate["shared_key"] = OWNER.hex()
        cache.configure_memory_store(candidate, lambda value: self.events.append(("refresh", value)))
        eid = proto.GetEidInfoForE2eeDevicesResponse()
        iv = bytes(range(12))
        eid.encryptedOwnerKeyAndMetadata.encryptedOwnerKey = iv + AESGCM(OWNER).encrypt(iv, OWNER, None)
        client = Mock()
        client.__enter__ = Mock(return_value=client)
        client.__exit__ = Mock(return_value=False)
        client.post.return_value = Mock(status_code=200, headers={},
                                        content=GrpcParser.construct_grpc(eid.SerializeToString()))
        with patch.object(self.adapter, "oauth", return_value=SECRET), patch.object(httpx, "Client", return_value=client):
            self.assertEqual(self.adapter.owner_key(), OWNER)
        encoded = client.post.call_args.kwargs["content"]
        query = common.GetEidInfoForE2eeDevicesRequest.FromString(GrpcParser.extract_grpc_payload(encoded))
        self.assertEqual(query.ownerKeyVersion, -1)
        self.assertTrue(query.hasOwnerKeyVersion)
        self.assertEqual(cache.get_cached_value("owner_key"), OWNER.hex())

    def test_poll_correlates_device_and_uuid_after_registration(self):
        self.adapter.request["device_id"] = "synthetic-tracker"
        tracker = Mock()
        callback_holder = {}
        tracker.start.side_effect = lambda callback: callback_holder.update(callback=callback) or "registration"
        def nova(scope, encoded):
            _, proto, _ = load_upstream()
            action = proto.ExecuteActionRequest.FromString(encoded)
            fixture = update()
            fixture.fcmMetadata.requestUuid = "wrong"
            callback_holder["callback"](fixture.SerializeToString().hex())
            fixture.fcmMetadata.requestUuid = action.requestMetadata.requestUuid
            fixture.deviceMetadata.identifierInformation.canonicIds.canonicId[0].id = "wrong-device"
            callback_holder["callback"](fixture.SerializeToString().hex())
            fixture.deviceMetadata.identifierInformation.canonicIds.canonicId[0].id = "synthetic-tracker"
            callback_holder["callback"](fixture.SerializeToString().hex())
            return b""
        with patch.object(self.adapter, "list_devices", return_value={"devices": [{"id": "synthetic-tracker"}]}), patch("worker.adapter.FCMTransport", return_value=tracker), patch.object(self.adapter, "nova", side_effect=nova):
            result = self.adapter.poll()
        self.assertEqual(len(result["sightings"]), 2)
        tracker.start.assert_called_once()
        self.adapter.close()
        tracker.close.assert_called()

    def test_http_categories(self):
        for status, code in ((401, "authentication-required"), (403, "authentication-required"),
                             (429, "rate-limited"), (503, "network-unavailable"), (400, "protocol-error")):
            with self.assertRaises(WorkerError) as error:
                check_http(Mock(status_code=status, headers={"Retry-After": "60"}))
            self.assertEqual(error.exception.code, code)
            if status == 429:
                self.assertEqual(error.exception.retry_after_ms, 60000)

    def test_fcm_actual_receiver_notification_and_owned_loop_cleanup(self):
        from Auth.fcm_receiver import FcmReceiver
        transport = FCMTransport(lambda: 2)
        pc = transport.receiver.pc
        async def checkin():
            return "registration"
        async def start():
            pc.stopping_lock = asyncio.Lock()
            pc.tasks = [asyncio.create_task(asyncio.sleep(100))]
        with patch.object(pc, "checkin_or_register", side_effect=checkin), patch.object(pc, "start", side_effect=start), patch.object(pc, "is_started", return_value=True):
            received = []
            self.assertEqual(transport.start(received.append), "registration")
            transport.receiver._on_notification(
                {"data": {"com.google.android.apps.adm.FCM_PAYLOAD": base64.b64encode(b"fixture").decode()}}, None, None)
            self.assertEqual(received, [b"fixture".hex()])
        transport.close()
        transport.close()
        self.assertFalse(transport.thread.is_alive())
        self.assertTrue(transport.loop.is_closed())
        self.assertEqual(transport.receiver.location_update_callbacks, [])

    def test_fcm_registration_deadline_cancels_and_closes_loop(self):
        transport = FCMTransport(lambda: 0.05)
        async def blocked_registration():
            await asyncio.sleep(100)
        try:
            with patch.object(transport.receiver.pc, "checkin_or_register", side_effect=blocked_registration):
                with self.assertRaises(WorkerError) as error:
                    transport.start(lambda value: None)
            self.assertEqual(error.exception.code, "timeout")
        finally:
            transport.close()
        self.assertFalse(transport.thread.is_alive())
        self.assertTrue(transport.loop.is_closed())

    def test_absent_accuracy_remains_unknown(self):
        fixture = update()
        reports = fixture.deviceMetadata.information.locationInformation.reports.recentLocationAndNetworkLocations
        reports.networkLocations[0].geoLocation.ClearField("accuracy")
        result = normalize_update(fixture, "synthetic-tracker", OWNER)
        self.assertIsNone(result["sightings"][0]["accuracy"])

    def test_diagnostic_sink_drops_all_sensitive_content(self):
        from worker.__main__ import DiagnosticSink, classify
        sink = DiagnosticSink()
        text = SECRET + " planted@example.invalid 12.3456"
        self.assertEqual(sink.write(text), len(text))
        self.assertEqual(classify(RuntimeError(SECRET)).code, "internal-error")


if __name__ == "__main__":
    unittest.main()
