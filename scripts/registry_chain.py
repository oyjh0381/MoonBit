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
    image_root_body = (multi / 'index.json').read_bytes()
    image_root_pin = pin(image_root_body)
    blobs = {'sha256:' + p.name: p.read_bytes() for p in (source_layout / 'blobs/sha256').iterdir()}
    for digest, data in blobs.items():
        assert pin(data) == digest
    metadata = {root_pin: (INDEX, root_body), image_root_pin: (INDEX, image_root_body)}
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
    attachment = next(item for item in json.loads(root_body)['manifests']
                      if 'artifactType' in json.loads(blobs[item['digest']]))
    attachment_body = json.loads(blobs[attachment['digest']])
    attachment_payload_pin = attachment_body['layers'][0]['digest']
    advertisement = {**attachment, 'artifactType': attachment_body['artifactType']}
    advertisement.pop('annotations', None)
    if attachment_body.get('annotations'):
        advertisement['annotations'] = attachment_body['annotations']
    statement_media = 'application/vnd.in-toto+json'
    statement_type = 'https://example.org/moonoci/provenance/v1'
    statement_ads = {}
    statement_blobs = {}
    statement_metadata = {}
    for label, statement_subject in [('match', images[0]['digest']), ('wrong', images[1]['digest'])]:
        raw_statement = encode({
            '_type': 'https://in-toto.io/Statement/v1', 'predicateType': statement_type,
            'subject': [{'digest': {'sha256': statement_subject.split(':', 1)[1]}}],
        })
        statement_blobs[pin(raw_statement)] = raw_statement
        statement_blobs[pin(b'{}')] = b'{}'
        raw_manifest = encode({
            'schemaVersion': 2, 'mediaType': MANIFEST, 'artifactType': statement_media,
            'subject': {k: images[0][k] for k in ('mediaType', 'size', 'digest')},
            'config': {'mediaType': 'application/vnd.oci.empty.v1+json', 'size': 2, 'digest': pin(b'{}')},
            'layers': [{'mediaType': statement_media, 'size': len(raw_statement), 'digest': pin(raw_statement)}],
        })
        statement_metadata[pin(raw_manifest)] = (MANIFEST, raw_manifest)
        statement_ads[label] = {'mediaType': MANIFEST, 'size': len(raw_manifest),
                                'digest': pin(raw_manifest), 'artifactType': statement_media}
    state = dict(mode='normal', require_auth=True, reject_auth=False, redirect=False, realm=None,
                 omit_digest=False, requests=[], mirror_requests=[], token_requests=0, bad_scope=False, auth_leak=False, transient=0,
                 listing_mode='normal', statement=None)

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
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
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
            if path == f'/v2/{REPOSITORY}/referrers/{images[0]["digest"]}':
                query = parse_qs(urlsplit(self.path).query)
                next_page = bool(query.get('last'))
                advertised = dict(advertisement)
                if state['listing_mode'] == 'wrong-type':
                    advertised['artifactType'] = 'application/vnd.forged'
                if state['listing_mode'] == 'wrong-size':
                    advertised['size'] = 1
                if state['listing_mode'] == 'wrong-annotations':
                    advertised['annotations'] = {'forged': 'yes'}
                listing = encode(dict(schemaVersion=2, mediaType=INDEX, manifests=[] if next_page else [advertised]))
                if next_page and state['statement']:
                    listing = encode(dict(schemaVersion=2, mediaType=INDEX,
                                          manifests=[statement_ads[state['statement']]]))
                link = registry_origin + path + '?last=one'
                if state['listing_mode'] == 'foreign':
                    link = mirror_origin + path + '?last=one'
                if state['listing_mode'] == 'loop':
                    link = registry_origin + path
                self.send(200, listing, INDEX, pin(listing),
                          extra=None if next_page else {'Link': f'<{link}>; rel="next"'})
                return
            if path.startswith(f'/v2/{REPOSITORY}/manifests/'):
                if state['transient']:
                    state['transient'] -= 1
                    self.send(503, extra={'Retry-After': '0'})
                    return
                reference = path.rsplit('/', 1)[1]
                digest = root_pin if reference == 'release' else image_root_pin if reference == 'images' else reference
                entity = metadata.get(digest) or statement_metadata.get(digest)
                if entity is None:
                    self.send(404)
                    return
                media, body = entity
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
                entity = blobs.get(digest, statement_blobs.get(digest))
                if entity is None:
                    self.send(404)
                elif state['redirect'] and digest == layer_pin:
                    self.send(307, extra={'Location': mirror_origin + '/blob/' + digest})
                else:
                    body = entity
                    if state['mode'] == 'corrupt' and digest == layer_pin:
                        body = bytes([body[0] ^ 1]) + body[1:]
                    if state['mode'] == 'corrupt-attachment' and digest == attachment_payload_pin:
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

        listing = json.loads(run('registry-referrers', registry_origin, REPOSITORY, images[0]['digest'], '--allow-http'))
        assert listing['pages'] == 2 and listing['listing_exhausted'] and not listing['manifests_verified']
        assert listing['referrers'] == [advertisement] and listing['auth_requests'] == 1
        filtered = json.loads(run('registry-referrers', registry_origin, REPOSITORY, images[0]['digest'],
                                 '--allow-http', '--artifact-type', 'application/vnd.absent'))
        assert filtered['referrers'] == [] and filtered['pages'] == 2
        for mode in ('foreign', 'loop'):
            state['listing_mode'] = mode
            before = len(state['mirror_requests'])
            run('registry-referrers', registry_origin, REPOSITORY, images[0]['digest'], '--allow-http', status=4)
            assert len(state['mirror_requests']) == before
        state['listing_mode'] = 'normal'
        run('registry-referrers', registry_origin, REPOSITORY, images[0]['digest'], '--allow-http', '--max-pages', '1', status=5)

        def bundle(name, *options, status=0):
            output = directory / name
            text = run('registry-bundle', registry_origin, REPOSITORY, 'images', image_root_pin,
                       images[0]['digest'], output, '--allow-http', '--buffered', *options, status=status)
            if status:
                assert not output.exists() and not Path(str(output) + '.moonoci-staging').exists()
                return None
            return output, json.loads(text)

        bundled, bundle_statistics = bundle('verified-bundle')
        assert bundle_statistics['auth_requests'] == 1
        assert bundle_statistics['bundle']['associations_verified'] and not bundle_statistics['bundle']['signatures_verified']
        assert bundle_statistics['bundle']['referrers'] == [advertisement['digest']]
        assert (bundled / 'blobs/sha256' / image_root_pin.split(':')[1]).read_bytes() == image_root_body
        assert json.loads(run('verify-store', bundled))['valid']
        assert json.loads(run('artifact-gate', bundled, images[0]['digest'], 'application/spdx+json'))['allowed']
        flat_bundle = directory / 'bundle-images'
        run('flatten-pinned', bundled, pin((bundled / 'index.json').read_bytes()), flat_bundle, '--images-only')
        assert observe(flat_bundle) == observe(multi)
        _, cache_statistics = bundle('cached-bundle', '--cache', bundled)
        assert cache_statistics['accepted_network_bytes'] == '0'
        assert cache_statistics['discovery']['pages'] == 2
        assert cache_statistics['http_requests'] == 4  # 401, token, two listing pages; no content GETs.
        before = len(state['requests'])
        bundle('missing-pinned-referrer', '--attachment-pins', pin(b'unlisted'), status=5)
        preflight_paths = [path for _, path, _ in state['requests'][before:]]
        referrers_path = f'/v2/{REPOSITORY}/referrers/{images[0]["digest"]}'
        assert preflight_paths.count(referrers_path) >= 2
        assert all(path in (referrers_path, '/token') for path in preflight_paths)

        for mode in ('wrong-type', 'wrong-size', 'wrong-annotations'):
            state['listing_mode'] = mode
            bundle('bundle-' + mode, status=4)
        state['listing_mode'] = 'normal'
        state['mode'] = 'corrupt-attachment'
        bundle('bundle-bad-payload', status=5)
        state['mode'] = 'normal'
        assert (multi / 'index.json').read_bytes() == image_root_body

        for flag in ('--max-content-bytes', '--max-blob-bytes', '--max-metadata-bytes',
                     '--max-objects', '--max-visits', '--max-depth', '--max-http-requests'):
            pull(registry_origin, directory / ('quota-' + flag[2:]), flag, '1', status=5)
        pull(registry_origin, directory / 'quota-auth', '--max-auth-requests', '0', status=5)
        run('registry-referrers', registry_origin, REPOSITORY, images[0]['digest'],
            '--allow-http', '--max-page-bytes', '1', status=5)
        run('registry-referrers', registry_origin, REPOSITORY, images[0]['digest'],
            '--allow-http', '--max-listing-bytes', '1', status=5)
        before = len(state['requests'])
        for flag, value in [('--max-content-bytes', '9223372036854775808'), ('--max-objects', '0'),
                            ('--max-blob-bytes', '0'), ('--max-http-requests', '-1')]:
            pull(registry_origin, directory / ('bad-quota-' + flag[2:]), flag, value, status=2)
        assert len(state['requests']) == before

        for label, predicate, status in [('match', statement_type, 0),
                                         ('match', 'urn:wrong:predicate', 5),
                                         ('wrong', statement_type, 5)]:
            state['statement'] = label
            attachment_pin = statement_ads[label]['digest']
            output = directory / ('statement-admission-' + label + '-' + str(status))
            decision = json.loads(run('registry-admit', registry_origin, REPOSITORY, 'images',
                                      image_root_pin, images[0]['digest'], output, '--allow-http', '--buffered',
                                      '--require-artifact', 'application/spdx+json',
                                      '--statement-digest', attachment_pin, '--statement-predicate', predicate,
                                      status=status))
            assert decision['decision']['allowed']
            assert decision['statement_decision']['allowed'] == (status == 0)
            assert output.exists() == (status == 0)
            if not status:
                assert decision['statement_decision']['binding']['subject'] == images[0]['digest']
            assert not Path(str(output) + '.moonoci-staging').exists()
        state['statement'] = None

        admission_args = ['registry-admit', registry_origin, REPOSITORY, 'images', image_root_pin,
                          images[0]['digest']]
        admitted_path = directory / 'admitted-release'
        admitted = json.loads(run(*admission_args, admitted_path, '--allow-http', '--buffered',
                                  '--require-artifact', 'application/spdx+json'))
        assert admitted['eligible_for_publication'] and admitted['decision']['allowed']
        assert json.loads(run('verify-store', admitted_path))['valid']
        denied_path = directory / 'denied-release'
        denied = json.loads(run(*admission_args, denied_path, '--allow-http', '--buffered',
                                '--require-artifact', 'application/spdx+json',
                                '--require-artifact', 'application/vnd.missing-proof', status=5))
        assert not denied['eligible_for_publication'] and not denied['decision']['allowed']
        assert not denied_path.exists() and not Path(str(denied_path) + '.moonoci-staging').exists()
        before = len(state['requests'])
        run(*admission_args, directory / 'no-requirement', '--allow-http', status=2)
        run(*admission_args, directory / 'duplicate-requirement', '--allow-http',
            '--require-artifact', 'application/json', '--require-artifact', 'application/json', status=2)
        assert len(state['requests']) == before

        # A complete cache works even while the peer refuses all HTTP traffic.
        for name, rules, status in [
            ('recommended', {}, 5),
            ('explicit-dev', {'requireNumericNonroot': False, 'requireCommand': False}, 0),
            ('amd64-only', {'requireNumericNonroot': False, 'requireCommand': False,
                            'allowedPlatforms': [{'os': 'linux', 'architecture': 'amd64'}]}, 5),
        ]:
            policy = directory / (name + '.policy.json')
            policy.write_bytes(encode({'schemaVersion': 1, **rules}))
            output = directory / ('policy-admission-' + name)
            decision = json.loads(run(*admission_args, output, '--allow-http', '--buffered',
                                      '--require-artifact', 'application/spdx+json', '--release-policy', policy, status=status))
            assert decision['decision']['allowed']
            assert decision['release_decision']['images']['manifests_checked'] == 2
            assert decision['eligible_for_publication'] == (status == 0)
            if status:
                assert not output.exists() and not Path(str(output) + '.moonoci-staging').exists()
        invalid_policy = directory / 'invalid-admission.policy.json'
        invalid_policy.write_bytes(b'{"schemaVersion":1,"mistypedRule":true}')
        before = len(state['requests'])
        run(*admission_args, directory / 'invalid-admission', '--allow-http', '--require-artifact', 'application/json',
            '--release-policy', invalid_policy, status=2)
        assert len(state['requests']) == before

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
        state['transient'] = 2
        recovered = pull(registry_origin, directory / 'transient-recovered')
        assert recovered['retries'] == 2 and state['transient'] == 0
        state['transient'] = 1
        pull(registry_origin, directory / 'retry-disabled', '--retries', '0', status=3)
        state['transient'] = 0
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
        auth_loop_bounded=True, optional_digest_header=True, bounded_transient_retries=True, artifact_gate_consumed=True,
        paginated_referrers=True, local_type_filter=True, foreign_and_looping_pages_refused=True,
        verified_referrer_bundle=True, bundle_cache_content_requests=0, forged_advertisements_refused=True,
        absent_pinned_referrer_sent_no_content_requests=True,
        operator_resource_profiles=True, invalid_quotas_refused_before_http=True,
        admission_before_publication=True, missing_required_attachment_blocks_output=True,
        composed_all_platform_policy=True, bad_policy_refused_before_http=True,
        pinned_statement_admission=True, wrong_inner_subject_and_predicate_block_output=True,
        independent_image_observation=True, oras_registry_copy_verified=oras_verified,
        methods=sorted({request[0] for request in state['requests']}), source_writes=0)
    (directory / 'report.json').write_bytes(encode(report))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
