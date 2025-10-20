from spiffe import X509Source
from cryptography.hazmat.primitives import serialization
import secrets

def Session(x509_source: X509Source):
    # Serialize the public and private keys to PEM bytes
    private_bytes = x509_source.svid.private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption()
    ).decode()

    public_bytes = x509_source.svid.leaf.public_bytes(
        encoding=serialization.Encoding.PEM
    ).decode()

    print("Certificate Public Key PEM:")
    print(public_bytes.encode('utf-8'))
    print("-----")
    print("Certificate Private Key PEM:")
    print(private_bytes.encode('utf-8'))

Session(X509Source())
