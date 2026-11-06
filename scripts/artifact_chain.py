"""Build, attach, discover and export OCI artifacts through public Native commands.
Payload bytes, manifest relationships and referrers JSON are independently checked.
Optional ORAS validates the generated layout with a mature external client.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--oras', type=Path)
    args = parser.parse_args()
    directory = Path(tempfile.mkdtemp(prefix='artifacts-', dir=ROOT / '_build'))
    binary = args.binary.resolve()

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=120)
        if result.returncode != status:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    source = directory / 'source'
    source.mkdir()
    (source / 'data').write_bytes(b'image payload')
    specification = dict(schemaVersion=1, ref='demo', platform=dict(os='linux', architecture='amd64'),
                         layers=[dict(source=str(source), compression='gzip')], output=dict(layout=str(directory / 'image')))
    path = directory / 'build.json'
    path.write_text(json.dumps(specification), encoding='utf-8')
    run('build', path)
    image = directory / 'image'
    subject = json.loads((image / 'index.json').read_bytes())['manifests'][0]['digest']
    original_index = (image / 'index.json').read_bytes()
    # Illustrative documents; this consumer does not claim SPDX/in-toto semantic
    # schema validation or provenance/signature authenticity.
    documents = [
        ('application/spdx+json', 'sbom', b'{"spdxVersion":"SPDX-2.3","name":"example"}'),
        ('application/vnd.in-toto+json', 'provenance', b'{"_type":"https://in-toto.io/Statement/v1","predicateType":"example"}'),
    ]
    current = image
    artifacts = []
    for media_type, reference, content in documents:
        payload = directory / (reference + '.json')
        payload.write_bytes(content)
        destination = directory / reference
        digest = run('artifact-attach', current, subject, media_type, media_type, payload, reference, destination)
        observed = json.loads(run('artifact-inspect', destination, digest))
        assert observed['subject'] == subject and observed['subject_present']
        assert observed['payloads'][0]['digest'] == 'sha256:' + hashlib.sha256(content).hexdigest()
        extracted = directory / (reference + '-exported.json')
        run('artifact-payload', destination, digest, '0', extracted)
        assert extracted.read_bytes() == content
        run('artifact-payload', destination, digest, '0', extracted, status=3)
        assert extracted.read_bytes() == content
        artifacts.append((digest, content, reference))
        current = destination
    assert (image / 'index.json').read_bytes() == original_index
    verified = json.loads(run('verify-store', current))
    assert verified['valid'] and verified['images_checked'] == 1 and verified['artifacts_checked'] == 2
    listed = json.loads(run('referrers', current, subject))
    assert {d['artifactType'] for d in listed['manifests']} == {d[0] for d in documents}
    filtered = json.loads(run('referrers', current, subject, 'application/spdx+json'))
    assert len(filtered['manifests']) == 1
    first_digest, first_payload, _ = artifacts[0]
    exported = directory / 'artifact-only'
    run('artifact-export', current, first_digest, exported)
    observed_export = json.loads(run('artifact-inspect', exported, first_digest))
    assert observed_export['subject'] == subject and not observed_export['subject_present']
    assert json.loads(run('verify-store', exported))['valid']
    corrupted = directory / 'corrupted'
    shutil.copytree(current, corrupted)
    payload_digest = hashlib.sha256(first_payload).hexdigest()
    (corrupted / 'blobs/sha256' / payload_digest).write_bytes(b'!' * len(first_payload))
    assert not json.loads(run('verify-store', corrupted, status=5))['valid']
    oras_version = None
    if args.oras:
        oras = args.oras.resolve()
        oras_version = subprocess.check_output([str(oras), 'version'], text=True, encoding='utf-8', timeout=30).strip()
        for digest, payload, reference in artifacts:
            output = directory / (reference + '-oras-manifest.json')
            subprocess.run([str(oras), 'manifest', 'fetch', '--oci-layout', str(current) + ':' + reference,
                            '--output', str(output)], check=True, capture_output=True, timeout=60)
            raw = output.read_bytes()
            assert 'sha256:' + hashlib.sha256(raw).hexdigest() == digest
            manifest = json.loads(raw)
            assert manifest['subject']['digest'] == subject
            payload_pin = 'sha256:' + hashlib.sha256(payload).hexdigest()
            assert manifest['layers'][0]['digest'] == payload_pin
    report = dict(schema='moonoci.artifact-consumer.v1', subject=subject, artifacts=2,
                  original_image_unchanged=True, independent_payload_hashes=True,
                  referrer_filter_verified=True, export_preserves_weak_subject=True,
                  corrupt_payload_refused=True, oras_version=oras_version)
    (directory / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
