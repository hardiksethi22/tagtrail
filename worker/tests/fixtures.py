"""Synthetic protobuf/crypto fixtures; never copied from an account."""
import hashlib
import base64

from worker.adapter import load_upstream

SECRET = "PLANTED_SECRET_DO_NOT_LOG"
OWNER = bytes(range(32))
IDENTITY = bytes(range(32, 64))


def bundle():
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    key = ec.derive_private_key(7, ec.SECP256R1())
    private = key.private_bytes(serialization.Encoding.DER,
                                serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
    public = key.public_key().public_bytes(serialization.Encoding.X962,
                                          serialization.PublicFormat.UncompressedPoint)
    return {"username": "planted@example.invalid", "aas_token": SECRET,
            "owner_key": OWNER.hex(),
            "fcm_credentials": {
                "gcm": {"android_id": "123456", "security_token": "987654",
                        "token": SECRET, "app_id": "synthetic-app"},
                "keys": {"private": base64.urlsafe_b64encode(private).decode(),
                         "public": base64.urlsafe_b64encode(public).decode(),
                         "secret": base64.urlsafe_b64encode(bytes(range(16))).decode()},
                "fcm": {"registration": {"token": SECRET},
                        "installation": {"token": SECRET, "refresh_token": SECRET}}}}


def device_list():
    _, proto, _ = load_upstream()
    result = proto.DevicesList()
    item = result.deviceMetadata.add()
    item.identifierInformation.type = proto.IDENTIFIER_SPOT
    item.identifierInformation.canonicIds.canonicId.add().id = "synthetic-tracker"
    item.userDefinedDeviceName = "合成 Tracker"
    return result


def update(mode="gcm"):
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from FMDNCrypto.foreign_tracker_cryptor import encrypt
    from FMDNCrypto.eid_generator import generate_eid
    common, proto, _ = load_upstream()
    result = proto.DeviceUpdate()
    result.deviceMetadata.CopyFrom(device_list().deviceMetadata[0])
    registration = result.deviceMetadata.information.deviceRegistration
    if mode == "cbc":
        iv = bytes(range(16))
        enc = Cipher(algorithms.AES(OWNER), modes.CBC(iv)).encryptor()
        registration.encryptedUserSecrets.encryptedIdentityKey = iv + enc.update(IDENTITY) + enc.finalize()
    else:
        iv = bytes(range(12))
        registration.encryptedUserSecrets.encryptedIdentityKey = iv + AESGCM(OWNER).encrypt(iv, IDENTITY, None)
    reports = result.deviceMetadata.information.locationInformation.reports.recentLocationAndNetworkLocations
    location = proto.Location(latitude=0, longitude=1200000000, altitude=4)
    geographic = reports.networkLocations.add()
    geographic.status = common.CROWDSOURCED
    geographic.geoLocation.accuracy = 12.5
    encrypted = geographic.geoLocation.encryptedReport
    if mode == "foreign":
        timestamp = 0x0084D000
        eid = generate_eid(IDENTITY, timestamp)
        ciphertext, public = encrypt(location.SerializeToString(), bytes(range(32)), eid)
        encrypted.encryptedLocation = ciphertext
        encrypted.publicKeyRandom = public
        geographic.geoLocation.deviceTimeOffset = timestamp
    else:
        iv = bytes(range(12))
        encrypted.encryptedLocation = iv + AESGCM(hashlib.sha256(IDENTITY).digest()).encrypt(
            iv, location.SerializeToString(), None)
    reports.networkLocationTimestamps.add(seconds=1732120000, nanos=123000000)
    semantic = reports.networkLocations.add()
    semantic.status = common.SEMANTIC
    semantic.semanticLocation.locationName = "Synthetic Home"
    reports.networkLocationTimestamps.add(seconds=1732120010)
    return result
