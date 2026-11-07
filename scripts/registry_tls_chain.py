"""Private-CA HTTPS pull and negative hostname/trust tests; no OS trust changes.

Development dependency: cryptography. Keys/certificates are generated per run
under ignored _build and are never packaged with the library.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='registry-tls-', dir=ROOT / '_build'))
    environment = dict(os.environ)
    environment.pop('MOONOCI_REGISTRY_TOKEN', None)

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT, env=environment,
                                capture_output=True, text=True, encoding='utf-8', timeout=60)
        if result.returncode != status:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    source = directory / 'rootfs'
    source.mkdir()
    (source / 'hello').write_bytes(b'authenticated TLS content')
    layout = directory / 'source'
    spec = directory / 'build.json'
    spec.write_text(json.dumps(dict(schemaVersion=1, ref='tls', layers=[dict(source=str(source), compression='none')],
                                   output=dict(layout=str(layout)))),'utf-8')
    run('build', spec)
    body = (layout / 'index.json').read_bytes()
    pin = digest(body)
    blobs = {'sha256:' + p.name:p.read_bytes() for p in (layout / 'blobs/sha256').iterdir()}
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'MoonOCI ephemeral TLS fixture')])
    now = datetime.now(timezone.utc)
    certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
        .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=1)).add_extension(x509.BasicConstraints(ca=True,path_length=0),critical=True)
        .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]),critical=False)
        .sign(key, hashes.SHA256()))
    cert = directory / 'ca-and-server.pem'
    private = directory / 'ephemeral-key.pem'
    cert.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, private)
    requests = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def do_GET(self):
            requests.append(self.path)
            if '/manifests/' in self.path:
                requested = self.path.rsplit('/',1)[1]
                data = body if requested in ('release',pin) else blobs.get(requested)
                media = 'application/vnd.oci.image.index.v1+json' if data == body else 'application/vnd.oci.image.manifest.v1+json'
            else:
                data = blobs.get(self.path.rsplit('/',1)[1])
                media = 'application/octet-stream'
            self.send_response(200 if data is not None else 404)
            self.send_header('Content-Length', str(len(data or b'')))
            self.send_header('Content-Type',media)
            self.send_header('Connection','close')
            self.end_headers()
            self.close_connection=True
            if data is not None:
                self.wfile.write(data)

    @contextmanager
    def server(host):
        peer=ThreadingHTTPServer((host,0),Handler)
        peer.daemon_threads=True
        peer.socket=context.wrap_socket(peer.socket, server_side=True)
        thread=threading.Thread(target=lambda:peer.serve_forever(poll_interval=0.05),daemon=True)
        thread.start()
        try:
            yield f'https://{host}:{peer.server_address[1]}'
        finally:
            peer.shutdown();peer.server_close();thread.join(timeout=5)

    options=['--retries','0','--timeout-ms','5000','--total-timeout-ms','15000','--buffered']
    with server('127.0.0.1') as origin:
        refused=directory/'untrusted-refused'
        run('registry-pull',origin,'tls/app','release',pin,refused,*options,status=3)
        assert not refused.exists() and not requests
        output=directory/'trusted'
        statistics=json.loads(run('registry-pull',origin,'tls/app','release',pin,output,*options,'--ca-file',cert))
        assert (output/'index.json').read_bytes()==body
        assert {'sha256:'+p.name:p.read_bytes() for p in (output/'blobs/sha256').iterdir()}==blobs
        assert statistics['core']['complete'] and json.loads(run('verify-store',output))['valid']
    before=len(requests)
    with server('127.0.0.2') as wrong_origin:
        refused=directory/'hostname-refused'
        run('registry-pull',wrong_origin,'tls/app','release',pin,refused,*options,'--ca-file',cert,status=3)
        assert not refused.exists() and len(requests)==before
    report=dict(schema='moonoci.registry-tls.v1', private_ca_pull=True, default_untrusted_refused=True,
                wrong_hostname_refused=True, os_trust_store_modified=False, request_bytes_verified=True,
                source_root=pin, private_keys_published=False)
    (directory/'report.json').write_text(json.dumps(report,indent=2),'utf-8')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    main()
