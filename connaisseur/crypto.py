import hashlib
import base64
import binascii
import ecdsa
import rsa

def verify_signature(
    public_key: ecdsa.VerifyingKey, signature_base64: str, message: str
):
    """
    Verifies the given bas64-encoded signature with the base64-encoded public
    key and serialized message. The message should not contain any whitespaces.

    Raises ValidationError if unsuccessful.
    """
    signature = base64.b64decode(signature_base64)

    msg_bytes = bytearray(message, "utf-8")

    return public_key.verify(signature, msg_bytes, hashfunc=hashlib.sha256)

def verify_signature(
    public_key: rsa.PublicKey, signature_base64: str, message: str
):
    """
    Verifies the given bas64-encoded signature with the base64-encoded public
    key and serialized message. The message should not contain any whitespaces.

    Raises ValidationError if unsuccessful.
    """
    signature = base64.b64decode(signature_base64)

    msg_bytes = bytearray(message, "utf-8")

    return rsa.verify(msg_bytes, signature, public_key)

def load_key(pem_key: str):
    try:
        return ecdsa.VerifyingKey.from_pem(pem_key)
    except (ecdsa.der.UnexpectedDER, binascii.Error, TypeError, AttributeError) as err:
        raise ValueError from err
