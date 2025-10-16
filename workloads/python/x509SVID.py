from spiffe import X509Source
from cryptography.hazmat.primitives import serialization
import secrets
from tempfile import NamedTemporaryFile

def Session(x509_source: X509Source):
    # Create a temporary password for the private key file
    key_pass = secrets.token_hex(16)

    # Serialize the public and private keys to PEM bytes
    private_bytes = x509_source.svid.private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.BestAvailableEncryption(bytes(key_pass.encode('utf-8')))).decode()
    public_bytes = x509_source.svid.leaf.public_bytes(encoding=serialization.Encoding.PEM).decode()

    print(public_bytes.encode('utf-8'))

    # Store the key in a temporarily file.
    # Loading from memory is not supported by any HTTP library (without monkey-patching).
    # See:
    # 1. https://github.com/encode/httpx/issues/2114
    # 2. https://github.com/python/cpython/pull/2449#issuecomment-1429164471
    key_file = NamedTemporaryFile(delete=False)
    key_file.write(private_bytes.encode('utf-8')); key_file.seek(0)
    print(f"Key file location: {key_file.name}")

Session(X509Source())
