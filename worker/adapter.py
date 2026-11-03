"""Structured boundary over the pinned upstream's real protobuf and cryptography."""
import asyncio
import concurrent.futures
import hashlib
import math
from pathlib import Path
import queue
import sys
import threading
import time
import uuid

from worker.errors import WorkerError

UPSTREAM_SHA = "660be5395702ff7f1a6174f4ec4c865a57c7b527"


def load_upstream():
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[1]))
    vendor = root / "vendor" / "GoogleFindMyTools"
    if str(vendor) not in sys.path:
        sys.path.insert(0, str(vendor))
    from ProtoDecoders import Common_pb2, DeviceUpdate_pb2
    from Auth import token_cache
    return Common_pb2, DeviceUpdate_pb2, token_cache


def validate_bundle(bundle, complete=True):
    import base64
    from cryptography.exceptions import UnsupportedAlgorithm
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    if not isinstance(bundle, dict):
        raise WorkerError("authentication-required")
    if not all(isinstance(bundle.get(k), str) and bundle[k] for k in ("username", "aas_token")):
        raise WorkerError("authentication-required")
    try:
        creds = bundle["fcm_credentials"]
        gcm = creds["gcm"]
        if any(not isinstance(gcm[key], str) or not gcm[key].isdigit()
               for key in ("android_id", "security_token")):
            raise ValueError()
        if any(not 0 < int(gcm[key]) < 2 ** 64 for key in ("android_id", "security_token")):
            raise ValueError()
        for key in ("app_id", "token"):
            if not isinstance(gcm[key], str) or not gcm[key]:
                raise ValueError()
        if not isinstance(creds["fcm"]["registration"]["token"], str) or not creds["fcm"]["registration"]["token"]:
            raise ValueError()
        for key in ("private", "public", "secret"):
            if not isinstance(creds["keys"][key], str) or not creds["keys"][key]:
                raise ValueError()
        def decode_key(value):
            return base64.b64decode(value + "=" * (-len(value) % 4),
                                    altchars=b"-_", validate=True)
        private = serialization.load_der_private_key(decode_key(creds["keys"]["private"]), password=None)
        if not isinstance(private, ec.EllipticCurvePrivateKey) or not isinstance(private.curve, ec.SECP256R1):
            raise ValueError()
        public = private.public_key().public_bytes(serialization.Encoding.X962,
                                                  serialization.PublicFormat.UncompressedPoint)
        if decode_key(creds["keys"]["public"]) != public or len(decode_key(creds["keys"]["secret"])) != 16:
            raise ValueError()
        for key in ("token", "refresh_token"):
            if not isinstance(creds["fcm"]["installation"][key], str) or not creds["fcm"]["installation"][key]:
                raise ValueError()
        if complete and not ("owner_key" in bundle or "shared_key" in bundle):
            raise ValueError()
        for key in ("owner_key", "shared_key"):
            if key in bundle and (not isinstance(bundle[key], str) or
                                  len(bytes.fromhex(bundle[key])) not in (16, 24, 32)):
                raise ValueError()
    except (KeyError, ValueError, TypeError, UnsupportedAlgorithm):
        raise WorkerError("authentication-required") from None
    return bundle


def device_ids(metadata):
    common, proto, _ = load_upstream()
    identifier = metadata.identifierInformation
    if identifier.type == proto.IDENTIFIER_ANDROID:
        return [item.id for item in identifier.phoneInformation.canonicIds.canonicId]
    return [item.id for item in identifier.canonicIds.canonicId]


def normalize_update(update, device_id, owner_key):
    common, proto, _ = load_upstream()
    from KeyBackup.cloud_key_decryptor import decrypt_aes_gcm, decrypt_eik
    from FMDNCrypto.foreign_tracker_cryptor import decrypt
    from SpotApi.CreateBleDevice.config import mcu_fast_pair_model_id
    from SpotApi.CreateBleDevice.util import flip_bits

    registration = update.deviceMetadata.information.deviceRegistration
    reports = update.deviceMetadata.information.locationInformation.reports.recentLocationAndNetworkLocations
    is_mcu = registration.fastPairModelId == mcu_fast_pair_model_id
    locations = list(reports.networkLocations)
    times = list(reports.networkLocationTimestamps)
    pairs = [(loc, times[i] if i < len(times) else None)
             for i, loc in enumerate(locations)]
    rejected = max(0, len(times) - len(locations))
    if reports.HasField("recentLocation"):
        pairs.append((reports.recentLocation, reports.recentLocationTimestamp
                      if reports.HasField("recentLocationTimestamp") else None))
    identity = None
    sightings = []
    for loc, provider_time in pairs:
        try:
            sighting = {"device_id": device_id, "source": "google-find-my",
                        "timestamp_provenance": "unknown"}
            if provider_time is not None and (provider_time.seconds or provider_time.nanos):
                if provider_time.nanos >= 1_000_000_000:
                    raise ValueError()
                sighting["provider_timestamp_ms"] = provider_time.seconds * 1000 + provider_time.nanos // 1_000_000
                sighting["timestamp_provenance"] = "provider"
            if loc.status == common.SEMANTIC and loc.HasField("semanticLocation"):
                if not loc.semanticLocation.locationName:
                    raise ValueError()
                sighting.update(kind="semantic", semantic_label=loc.semanticLocation.locationName)
            else:
                if loc.status not in (common.LAST_KNOWN, common.CROWDSOURCED, common.AGGREGATED) or not loc.HasField("geoLocation"):
                    raise ValueError()
                if identity is None:
                    identity = decrypt_eik(owner_key, flip_bits(
                        registration.encryptedUserSecrets.encryptedIdentityKey, is_mcu))
                encrypted = loc.geoLocation.encryptedReport
                if not encrypted.encryptedLocation:
                    raise ValueError()
                if encrypted.publicKeyRandom:
                    if len(encrypted.publicKeyRandom) != 20:
                        raise ValueError()
                    plaintext = decrypt(identity, encrypted.encryptedLocation,
                                        encrypted.publicKeyRandom,
                                        0 if is_mcu else loc.geoLocation.deviceTimeOffset)
                else:
                    plaintext = decrypt_aes_gcm(hashlib.sha256(identity).digest(), encrypted.encryptedLocation)
                location = proto.Location.FromString(plaintext)
                # Proto3 scalars have no presence: a legitimate zero is preserved.
                latitude, longitude = location.latitude / 1e7, location.longitude / 1e7
                accuracy = loc.geoLocation.accuracy
                if not (-90 <= latitude <= 90 and -180 <= longitude <= 180) or not math.isfinite(accuracy) or accuracy < 0:
                    raise ValueError()
                sighting.update(kind="geographic", latitude=latitude, longitude=longitude,
                                altitude=location.altitude if any(field.name == "altitude" for field, _ in location.ListFields()) else None,
                                accuracy=accuracy if any(field.name == "accuracy" for field, _ in loc.geoLocation.ListFields()) else None)
            sightings.append(sighting)
        except Exception:
            rejected += 1
    if pairs and not sightings and rejected:
        raise WorkerError("decryption-error")
    return {"sightings": sightings, "rejected_count": rejected}


class FCMTransport:
    """Run registration, callbacks and shutdown on one owned asyncio loop."""
    def __init__(self, remaining):
        from Auth.fcm_receiver import FcmReceiver
        FcmReceiver._instance = None
        self.receiver = FcmReceiver()
        self.loop = asyncio.new_event_loop()
        self.remaining = remaining
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.closed = False

    def run(self, coroutine):
        future = asyncio.run_coroutine_threadsafe(coroutine, self.loop)
        try:
            return future.result(timeout=self.remaining())
        except concurrent.futures.TimeoutError:
            future.cancel()
            raise WorkerError("timeout") from None

    def start(self, callback):
        self.receiver.location_update_callbacks.append(callback)
        async def register_and_start():
            token = await self.receiver.pc.checkin_or_register()
            await self.receiver.pc.start()
            # Upstream start schedules tasks; wait until socket login completes.
            while not self.receiver.pc.is_started():
                await asyncio.sleep(0.05)
            return token
        return self.run(register_and_start())

    def register(self):
        return self.run(self.receiver.pc.checkin_or_register())

    def close(self):
        if self.closed:
            return
        self.closed = True
        async def shutdown():
            pc = self.receiver.pc
            if pc.stopping_lock is not None:
                await pc.stop()
            await pc._do_writer_close()
            if getattr(pc, "register", None):
                await pc.register.close()
            pending = [task for task in asyncio.all_tasks()
                       if task is not asyncio.current_task()]
            for task in pending:
                task.cancel()
            await asyncio.gather(*pending, return_exceptions=True)
        future = asyncio.run_coroutine_threadsafe(shutdown(), self.loop)
        try:
            future.result(timeout=2)
        except Exception:
            future.cancel()
        finally:
            self.loop.call_soon_threadsafe(self.loop.stop)
            self.thread.join(timeout=2)
            if not self.thread.is_alive():
                self.loop.close()
            self.receiver.location_update_callbacks.clear()


class GoogleAdapter:
    def __init__(self, request, emit, deadline):
        self.request = request
        self.emit = emit
        self.deadline = deadline
        self.fcm = None
        _, _, self.cache = load_upstream()
        self.cache.configure_memory_store(request.get("credential_bundle", {}),
                                          lambda bundle: emit("credential_update",
                                                              credential_bundle=bundle))

    def remaining(self):
        duration = self.deadline - time.monotonic()
        if duration <= 0:
            raise WorkerError("timeout")
        return duration

    def oauth(self, scope="android_device_manager", play_services=False):
        import gpsoauth
        import requests
        bundle = validate_bundle(self.cache.memory_snapshot())
        # gpsoauth lacks timeout/session injection. Use its exact Android auth
        # encoding/adapter, but close the session and bound every HTTP request.
        original = gpsoauth._perform_auth_request
        def bounded(data, proxies=None):
            with requests.Session() as session:
                session.mount(gpsoauth.AUTH_URL, gpsoauth.AuthHTTPAdapter())
                if proxies:
                    session.proxies = proxies
                session.headers.update({"Accept-Encoding": "identity",
                                        "Content-type": "application/x-www-form-urlencoded",
                                        "User-Agent": gpsoauth.USER_AGENT})
                response = session.post(gpsoauth.AUTH_URL, data=data, verify=True,
                                        timeout=min(15, self.remaining()))
                check_http(response)
                return gpsoauth.google.parse_auth_response(response.text)
        gpsoauth._perform_auth_request = bounded
        try:
            response = gpsoauth.perform_oauth(
                bundle["username"], bundle["aas_token"],
                str(bundle["fcm_credentials"]["gcm"]["android_id"]),
                service="oauth2:https://www.googleapis.com/auth/" + scope,
                app="com.google.android.gms" if play_services else "com.google.android.apps.adm",
                client_sig="38918a453d07199354f8b19af05ec6562ced5788")
            if not response.get("Auth"):
                raise WorkerError("authentication-required")
            return response["Auth"]
        finally:
            gpsoauth._perform_auth_request = original

    def nova(self, scope, payload):
        import requests
        token = self.oauth()
        response = requests.post(
            "https://android.googleapis.com/nova/" + scope,
            headers={"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                     "Authorization": "Bearer " + token, "Accept-Language": "en-US",
                     "User-Agent": "fmd/20006320; gzip"},
            data=payload, timeout=min(15, self.remaining()))
        check_http(response)
        if len(response.content) > 4 * 1024 * 1024:
            raise WorkerError("protocol-error")
        return response.content

    def list_devices(self):
        common, proto, _ = load_upstream()
        query = proto.DevicesListRequest()
        query.deviceListRequestPayload.type = proto.SPOT_DEVICE
        query.deviceListRequestPayload.id = str(uuid.uuid4())
        devices = proto.DevicesList.FromString(self.nova("nbe_list_devices", query.SerializeToString()))
        result = []
        seen = set()
        for metadata in devices.deviceMetadata:
            if metadata.identifierInformation.type != proto.IDENTIFIER_SPOT:
                continue
            for device_id in device_ids(metadata):
                if device_id and device_id not in seen:
                    result.append({"id": device_id, "name": metadata.userDefinedDeviceName,
                                   "network": "google"})
                    seen.add(device_id)
        return {"devices": result}

    def owner_key(self):
        from KeyBackup.cloud_key_decryptor import decrypt_owner_key
        common, proto, _ = load_upstream()
        bundle = self.cache.memory_snapshot()
        if bundle.get("owner_key"):
            return bytes.fromhex(bundle["owner_key"])
        import httpx
        from SpotApi.grpc_parser import GrpcParser
        token = self.oauth("spot", True)
        query = common.GetEidInfoForE2eeDevicesRequest()
        query.ownerKeyVersion = -1
        query.hasOwnerKeyVersion = True
        with httpx.Client(http2=True, timeout=min(15, self.remaining())) as client:
            response = client.post(
                "https://spot-pa.googleapis.com/google.internal.spot.v1.SpotService/GetEidInfoForE2eeDevices",
                headers={"User-Agent": "com.google.android.gms/244433022 grpc-java-cronet/1.69.0-SNAPSHOT",
                         "Content-Type": "application/grpc", "Te": "trailers",
                         "Authorization": "Bearer " + token, "Grpc-Accept-Encoding": "gzip"},
                content=GrpcParser.construct_grpc(query.SerializeToString()))
        check_http(response)
        if len(response.content) > 4 * 1024 * 1024 or not response.content or response.content[0] != 0:
            raise WorkerError("protocol-error")
        if response.headers.get("grpc-status", "0") != "0":
            raise WorkerError("authentication-required")
        try:
            eid = proto.GetEidInfoForE2eeDevicesResponse.FromString(
                GrpcParser.extract_grpc_payload(response.content))
        except ValueError:
            raise WorkerError("protocol-error") from None
        try:
            key = decrypt_owner_key(bytes.fromhex(bundle["shared_key"]),
                                    eid.encryptedOwnerKeyAndMetadata.encryptedOwnerKey)
        except Exception:
            raise WorkerError("decryption-error") from None
        self.cache.set_cached_value("owner_key", key.hex())
        return key

    def poll(self):
        _, proto, _ = load_upstream()
        from NovaApi.ExecuteAction.nbe_execute_action import create_action_request
        device_id = self.request["device_id"]
        if device_id not in {device["id"] for device in self.list_devices()["devices"]}:
            raise WorkerError("unsupported-device")
        request_uuid = str(uuid.uuid4())
        responses = queue.Queue(maxsize=32)
        def callback(hex_payload):
            try:
                update = proto.DeviceUpdate.FromString(bytes.fromhex(hex_payload))
                if update.fcmMetadata.requestUuid == request_uuid and device_id in device_ids(update.deviceMetadata):
                    responses.put_nowait(update)
            except Exception:
                pass
        self.fcm = FCMTransport(self.remaining)
        token = self.fcm.start(callback)
        action = create_action_request(device_id, token, request_uuid=request_uuid)
        action.action.locateTracker.lastHighTrafficEnablingTime.seconds = 1732120060
        action.action.locateTracker.contributorType = proto.FMDN_ALL_LOCATIONS
        self.nova("nbe_execute_action", action.SerializeToString())
        try:
            update = responses.get(timeout=self.remaining())
        except queue.Empty:
            raise WorkerError("timeout") from None
        return normalize_update(update, device_id, self.owner_key())

    def execute(self):
        command = self.request["command"]
        if command == "doctor":
            self.emit("progress", payload={"stage": "checking-dependencies"})
            import cryptography, google.protobuf, gpsoauth
            self.emit("progress", payload={"stage": "checking-fcm"})
            from Auth.fcm_receiver import FcmReceiver
            self.emit("progress", payload={"stage": "checking-crypto"})
            from FMDNCrypto.foreign_tracker_cryptor import decrypt
            from KeyBackup.cloud_key_decryptor import decrypt_eik
            return {"status": "ok", "protocol_version": 1, "upstream_commit": UPSTREAM_SHA,
                    "python": ".".join(map(str, sys.version_info[:3])),
                    "cryptography": cryptography.__version__,
                    "protobuf": google.protobuf.__version__,
                    "live_account_verified": False}
        if command == "authenticate" and self.request.get("browser_helper"):
            from worker.browser import authenticate_browser
            authenticate_browser(self)
        validate_bundle(self.cache.memory_snapshot())
        if command == "authenticate":
            self.oauth()
            self.owner_key()
            return {"status": "authenticated", "credential_storage": "parent-keychain"}
        if command == "list_devices":
            return self.list_devices()
        return self.poll()

    def close(self):
        if self.fcm:
            self.fcm.close()


def check_http(response):
    status = response.status_code
    if status == 429:
        retry = response.headers.get("Retry-After", "")
        delay = min(int(retry), 86400) * 1000 if retry.isdigit() else None
        raise WorkerError("rate-limited", delay)
    if status in (401, 403):
        raise WorkerError("authentication-required")
    if status >= 500:
        raise WorkerError("network-unavailable")
    if status != 200:
        raise WorkerError("protocol-error")
