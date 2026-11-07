"""Loopback Registry wire consumer, independent ORAS copy and hostile replies.

The Python server is a read-only fixture, not a production registry. It binds
only 127.0.0.1 and records no secret values. No Docker/Linux VM is required.
"""
import argparse
from contextlib import ExitStack, contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

from independent_layout import observe

ROOT = Path(__file__).resolve().parents[1]
INDEX = 'application/vnd.oci.image.index.v1+json'
MANIFEST = 'application/vnd.oci.image.manifest.v1+json'
TOKEN = 'fixture-read-token'
REPOSITORY = 'team/app'


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def pin(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


@contextmanager
def serve(handler):
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    server.daemon_threads = True
    thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_address[1]}'
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--oras', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='registry-', dir=ROOT / '_build'))
    environment = dict(os.environ)
    # Never send a user's ambient registry credential to a fixture.
    environment.pop('MOONOCI_REGISTRY_TOKEN', None)

    def run(*arguments, status=0, extra_env=None):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT,
            env={**environment, **(extra_env or {})}, capture_output=True, text=True, encoding='utf-8', timeout=120)
        expected = {status} if isinstance(status, int) else set(status)
        if result.returncode not in expected:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        assert TOKEN not in result.stdout + result.stderr
        return result.stdout.strip()

    source = directory / 'rootfs'
    source.mkdir()
    (source / 'shared.bin').write_bytes(bytes(range(256)) * 256)
    images = []
    for arch in ('amd64', 'arm64'):
        layout = directory / arch
        specification = directory / (arch + '.json')
        specification.write_bytes(encode(dict(schemaVersion=1, ref=arch,
            platform=dict(os='linux', architecture=arch), layers=[dict(source=str(source), compression='none')],
            output=dict(layout=str(layout)))))
        run('build', specification)
        images.append(json.loads((layout / 'index.json').read_bytes())['manifests'][0])
    multi = directory / 'multi'
    run('merge', multi, directory / 'amd64', directory / 'arm64')
    payload = directory / 'attachment.json'
    payload.write_bytes(b'{"fixture":"typed-attachment"}')
    source_layout = directory / 'source-layout'
    run('artifact-attach', multi, images[0]['digest'], 'application/spdx+json', 'application/json', payload, 'attachment', source_layout)
    root_body = (source_layout / 'index.json').read_bytes()
    root_pin = pin(root_body)  # Independently supplied release metadata.
    blobs = {'sha256:' + p.name: p.read_bytes() for p in (source_layout / 'blobs/sha256').iterdir()}
    for digest, data in blobs.items():
        assert pin(data) == digest
    metadata = {root_pin: (INDEX, root_body)}
    for digest, data in blobs.items():
        try:
            value = json.loads(data)
        except (ValueError, UnicodeDecodeError):
            continue
        if isinstance(value, dict) and value.get('schemaVersion') == 2:
            media = value.get('mediaType', INDEX if 'manifests' in value else MANIFEST)
            metadata[digest] = (media, data)
    first_manifest = json.loads(blobs[images[0]['digest']])
    layer_pin = first_manifest['layers'][0]['digest']
    state = dict(mode='normal', require_auth=True, reject_auth=False, redirect=False, realm=None,
                 omit_digest=False, requests=[], mirror_requests=[], token_requests=0, bad_scope=False, auth_leak=False)

    class Base(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def send(self, status, data=b'', media='application/json', digest=None, extra=None, length=None):
            self.send_response(status)
            self.send_header('Content-Type', media + '; charset=utf-8')
            self.send_header('Content-Length', str(len(data) if length is None else length))
            self.send_header('Connection', 'close')
            if digest and not state['omit_digest']:
                self.send_header('Docker-Content-Digest', digest)
                if state['mode'] == 'duplicate-digest':
                    self.send_header('docker-content-digest', digest)
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            self.close_connection = True
            if self.command != 'HEAD':
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        def token(self):
            query = parse_qs(urlsplit(self.path).query)
            state['token_requests'] += 1
            if self.headers.get('Authorization'):
                state['auth_leak'] = True
            if query.get('scope') != [f'repository:{REPOSITORY}:pull'] or query.get('offline_token'):
                state['bad_scope'] = True
                self.send(403)
            else:
                self.send(200, encode({'token': TOKEN}))

    class Mirror(Base):
        def do_GET(self):
            state['mirror_requests'].append((self.path, bool(self.headers.get('Authorization'))))
            if self.headers.get('Authorization'):
                state['auth_leak'] = True
                self.send(403)
            elif urlsplit(self.path).path == '/token':
                self.token()
            else:
                digest = urlsplit(self.path).path.removeprefix('/blob/')
                if digest in blobs:
                    self.send(200, blobs[digest], 'application/octet-stream', digest)
                else:
                    self.send(404)

        do_HEAD = do_GET

    class Registry(Base):
        def do_GET(self):
            path = urlsplit(self.path).path
            state['requests'].append((self.command, path, bool(self.headers.get('Authorization'))))
            if path == '/token':
                self.token()
                return
            if state['mode'] == 'forbid-all':
                self.send(503)
                return
            if state['require_auth'] and (state['reject_auth'] or self.headers.get('Authorization') != 'Bearer ' + TOKEN):
                realm = state['realm'] or registry_origin + '/token'
                self.send(401, extra={'WWW-Authenticate': f'Bearer realm="{realm}",service="fixture",scope="repository:{REPOSITORY}:pull,push"'})
                return
            if path == '/v2/':
                self.send(200, b'{}')
                return
            if path.startswith(f'/v2/{REPOSITORY}/manifests/'):
                reference = path.rsplit('/', 1)[1]
                digest = root_pin if reference == 'release' else reference
                if digest not in metadata:
                    self.send(404)
                    return
                media, body = metadata[digest]
                if state['mode'] == 'slow':
                    time.sleep(0.4)
                if state['mode'] == 'wrong-media':
                    media = MANIFEST if media == INDEX else INDEX
                length = len(body) + 16777216 if state['mode'] == 'oversized' else len(body)
                if state['mode'] == 'truncated':
                    body = body[:-1]
                extra = {'Content-Encoding': 'gzip'} if state['mode'] == 'encoded' else None
                self.send(200, body, media, digest, extra=extra, length=length)
            elif path.startswith(f'/v2/{REPOSITORY}/blobs/'):
                digest = path.rsplit('/', 1)[1]
                if digest not in blobs:
                    self.send(404)
                elif state['redirect'] and digest == layer_pin:
                    self.send(307, extra={'Location': mirror_origin + '/blob/' + digest})
                else:
                    body = blobs[digest]
                    if state['mode'] == 'corrupt' and digest == layer_pin:
                        body = bytes([body[0] ^ 1]) + body[1:]
                    self.send(200, body, 'application/octet-stream', digest)
            else:
                self.send(404)

        do_HEAD = do_GET

    def pull(origin, output, *options, status=0, extra_env=None, expected=root_pin):
        result = run('registry-pull', origin, REPOSITORY, 'release', expected, output,
                     '--allow-http', '--buffered', *options, status=status, extra_env=extra_env)
        if status != 0:
            assert not output.exists() and not Path(str(output) + '.moonoci-staging').exists()
            return None
        return json.loads(result)

    with ExitStack() as stack:
        mirror_origin = stack.enter_context(serve(Mirror))
        registry_origin = stack.enter_context(serve(Registry))
        result = directory / 'downloaded'
        statistics = pull(registry_origin, result)
        assert statistics['auth_requests'] == 1 and not state['bad_scope'] and not state['auth_leak']
        assert (result / 'index.json').read_bytes() == root_body
        actual = {'sha256:' + p.name: p.read_bytes() for p in (result / 'blobs/sha256').iterdir()}
        assert actual == blobs
        assert json.loads(run('verify-store', result))['valid']
        assert json.loads(run('artifact-gate', result, images[0]['digest'], 'application/spdx+json'))['allowed']
        flat = directory / 'images-only'
        run('flatten-pinned', result, root_pin, flat, '--images-only')
        assert observe(flat) == observe(multi)

        # A complete cache works even while the peer refuses all HTTP traffic.
        state['mode'] = 'forbid-all'
        before = len(state['requests'])
        cached = pull(registry_origin, directory / 'cached', '--cache', result)
        assert cached['http_requests'] == 0 and cached['core']['accepted_network_bytes'] == '0'
        assert cached['core']['cached_requests'] == cached['core']['accepted_requests']
        assert len(state['requests']) == before
        corrupt_cache = directory / 'corrupt-cache'
        shutil.copytree(result, corrupt_cache)
        cache_blob = corrupt_cache / 'blobs/sha256' / layer_pin.split(':')[1]
        bad_bytes = cache_blob.read_bytes()
        cache_blob.write_bytes(bytes([bad_bytes[0] ^ 1]) + bad_bytes[1:])
        pull(registry_origin, directory / 'cache-refused', '--cache', corrupt_cache, status=5)

        state.update(mode='normal', require_auth=True, redirect=True)
        before_mirror = len(state['mirror_requests'])
        pull(registry_origin, directory / 'redirect-refused', status=2)
        assert len(state['mirror_requests']) == before_mirror
        pull(registry_origin, directory / 'redirect-allowed', '--allow-blob-origin', mirror_origin)
        assert len(state['mirror_requests']) > before_mirror and not state['auth_leak']

        state.update(redirect=False, realm=mirror_origin + '/token')
        before_mirror = len(state['mirror_requests'])
        pull(registry_origin, directory / 'realm-refused', status=2)
        assert len(state['mirror_requests']) == before_mirror
        pull(registry_origin, directory / 'realm-allowed', '--allow-realm', mirror_origin,
             extra_env={'MOONOCI_REGISTRY_TOKEN': 'invalid-fixture-token'})
        assert not state['auth_leak']
        state.update(realm=None, require_auth=False)
        for mode, statuses in [('corrupt', 5), ('oversized', 5), ('truncated', {3, 5}),
                               ('wrong-media', 4), ('encoded', 4), ('duplicate-digest', 5)]:
            state['mode'] = mode
            pull(registry_origin, directory / ('refused-' + mode), status=statuses)
        state['mode'] = 'slow'
        pull(registry_origin, directory / 'timeout-refused', '--timeout-ms', '80', status=3)
        state.update(mode='normal', require_auth=True, reject_auth=True)
        before = state['token_requests']
        pull(registry_origin, directory / 'auth-loop-refused', status=5)
        assert state['token_requests'] - before == 2
        state.update(require_auth=False, reject_auth=False, omit_digest=True)
        pull(registry_origin, directory / 'no-digest-header')
        state['omit_digest'] = False
        pull(registry_origin, directory / 'wrong-pin', expected='sha256:' + '0' * 64, status=5)
        before = len(state['requests'])
        run('registry-pull', registry_origin, REPOSITORY, 'release', root_pin, directory / 'http-refused', status=2)
        assert len(state['requests']) == before
        run('registry-pull', registry_origin, REPOSITORY, 'release', root_pin, result, '--allow-http', status=3)

        oras_verified = False
        if args.oras:
            config = directory / 'empty-auth.json'
            config.write_bytes(b'{"auths":{}}')
            oracle = directory / 'oras-copy'
            target = registry_origin.removeprefix('http://') + '/' + REPOSITORY + ':release'
            subprocess.run([str(args.oras.resolve()), 'cp', '--from-plain-http', '--from-registry-config', str(config),
                '--to-oci-layout', target, str(oracle) + ':release'], check=True, capture_output=True, timeout=120, env=environment)
            oracle_blobs = {'sha256:' + p.name: p.read_bytes() for p in (oracle / 'blobs/sha256').iterdir()}
            assert oracle_blobs == {**blobs, root_pin: root_body}
            assert json.loads(run('verify-store', oracle))['valid']
            oras_verified = True
        assert not state['bad_scope'] and not state['auth_leak']
    report = dict(schema='moonoci.registry-consumer.v1', source_root=root_pin, images=2, typed_attachments=1,
        content_objects=len(blobs), accepted_network_bytes=statistics['core']['accepted_network_bytes'],
        cache_http_requests=cached['http_requests'], authenticated_pull=True, pull_only_scope=True,
        redirect_and_realm_allowlists=True, no_cross_origin_authorization=True, corrupt_cache_refused=True,
        malformed_and_interrupted_responses_refused=True, request_timeouts_verified=True,
        auth_loop_bounded=True, optional_digest_header=True, artifact_gate_consumed=True,
        independent_image_observation=True, oras_registry_copy_verified=oras_verified,
        methods=sorted({request[0] for request in state['requests']}), source_writes=0)
    (directory / 'report.json').write_bytes(encode(report))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
