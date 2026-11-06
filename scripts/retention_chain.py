"""Independent mixed OCI retention consumer; Windows/Linux, no daemon needed."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from independent_layout import observe

ROOT = Path(__file__).resolve().parents[1]


def digest(data):
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def encode(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def blob_path(layout, pin):
    algorithm, encoded = pin.split(':')
    assert algorithm == 'sha256' and len(encoded) == 64
    return layout / 'blobs' / algorithm / encoded


def manifest_closure(layout, pin):
    raw = blob_path(layout, pin).read_bytes()
    assert digest(raw) == pin
    manifest = json.loads(raw)
    result = {pin}
    for item in [manifest['config'], *manifest['layers']]:
        payload = blob_path(layout, item['digest']).read_bytes()
        assert len(payload) == item['size'] and digest(payload) == item['digest']
        result.add(item['digest'])
    return result


def physical(layout):
    result = {}
    for path in (layout / 'blobs' / 'sha256').iterdir():
        data = path.read_bytes()
        pin = 'sha256:' + path.name
        assert digest(data) == pin
        result[pin] = len(data)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--oras', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='retention-', dir=ROOT / '_build'))

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=120)
        if result.returncode != status:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    source = directory / 'rootfs'
    source.mkdir()
    (source / 'app').write_bytes(b'retention demo')
    images = []
    for arch in ('amd64', 'arm64'):
        target = directory / arch
        specification = directory / (arch + '.json')
        specification.write_bytes(encode(dict(schemaVersion=1, ref=arch,
            platform=dict(os='linux', architecture=arch), layers=[dict(source=str(source), compression='none')],
            output=dict(layout=str(target)))))
        run('build', specification)
        images.append(json.loads((target / 'index.json').read_bytes())['manifests'][0]['digest'])
    multi = directory / 'multi'
    run('merge', multi, directory / 'amd64', directory / 'arm64')
    release_pin = digest((multi / 'index.json').read_bytes())
    current = multi
    attached = {}
    for name, subject, artifact_type in [
        ('release', release_pin, 'application/spdx+json'),
        ('app', images[0], 'application/spdx+json'),
        ('signature-demo', None, 'application/vnd.in-toto+json'),
        ('other', images[1], 'application/spdx+json'),
    ]:
        if subject is None:
            subject = attached['app']
        payload = directory / (name + '-payload.json')
        payload.write_bytes(encode({'fixture': name}))
        target = directory / ('attached-' + name)
        attached[name] = run('artifact-attach', current, subject, artifact_type, 'application/json', payload, name, target)
        current = target
    root = json.loads((current / 'index.json').read_bytes())
    root['x-revision'] = 9007199254740993
    root['manifests'][0]['x-caller'] = {'team': 'application'}
    root['manifests'].append({**root['manifests'][0], 'annotations': {'org.opencontainers.image.ref.name': 'stable'}})
    (current / 'index.json').write_bytes(encode(root))
    orphan = b'unadvertised content'
    blob_path(current, digest(orphan)).write_bytes(orphan)
    source_pin = digest((current / 'index.json').read_bytes())
    stored = physical(current)
    catalog = json.loads(run('content-catalog', current, source_pin))
    assert int(catalog['stored_bytes']) == sum(stored.values())
    assert catalog['stored_blobs'] == len(stored) and catalog['content_only']
    store_text = ('moonoci.store.v1\n' + source_pin + '\n' + digest((current / 'oci-layout').read_bytes()) + '\n' +
                  '\n'.join(pin + ' ' + str(stored[pin]) for pin in sorted(stored)) + '\n')
    assert catalog['store_pin'] == digest(store_text.encode())
    expected = (manifest_closure(current, images[0]) | manifest_closure(current, attached['app']) |
                manifest_closure(current, attached['signature-demo']))
    plan = json.loads(run('retain-plan', current, source_pin, 'referrers', images[0]))
    assert set(plan['kept']) == expected
    assert set(plan['discarded']) == set(stored) - expected
    assert int(plan['reclaimable_bytes']) == sum(stored[pin] for pin in set(stored) - expected)
    announced = {images[0], attached['app'], attached['signature-demo']}
    expected_root = {**root, 'manifests': [d for d in root['manifests'] if d['digest'] in announced]}
    assert plan['output_index'] == digest(encode(expected_root))
    review_text = '\n'.join(['moonoci.retention.v1', plan['source_store'], plan['output_index'], 'true', 'false',
                             'selected', images[0], 'kept', '\n'.join(sorted(expected)),
                             'discarded', '\n'.join(sorted(set(stored) - expected))]) + '\n'
    assert plan['plan_pin'] == digest(review_text.encode())
    output = directory / 'retained-app'
    exported = json.loads(run('retain-export', current, source_pin, plan['plan_pin'], 'referrers', output, images[0]))
    assert exported == plan and physical(output) == {pin: stored[pin] for pin in expected}
    assert (output / 'index.json').read_bytes() == encode(expected_root)
    assert images[1] not in physical(output) and attached['other'] not in physical(output)
    assert release_pin not in physical(output) and digest(orphan) not in physical(output)
    assert json.loads(run('verify-store', output))['valid']
    assert physical(current) == stored
    assert digest((current / 'index.json').read_bytes()) == source_pin
    run('retain-export', current, source_pin, plan['plan_pin'], 'referrers', output, images[0], status=3)

    # Independently consume the retained runnable image without attachment roots.
    image_view = directory / 'image-view'
    shutil.copytree(output, image_view)
    (image_view / 'index.json').write_bytes((directory / 'amd64' / 'index.json').read_bytes())
    assert observe(image_view) == observe(directory / 'amd64')
    minimal_plan = json.loads(run('retain-plan', current, source_pin, 'closure', attached['app']))
    minimal = directory / 'artifact-only'
    run('retain-export', current, source_pin, minimal_plan['plan_pin'], 'closure', minimal, attached['app'])
    assert images[0] not in physical(minimal)
    complete_plan = json.loads(run('retain-plan', current, source_pin, 'complete', attached['app']))
    assert set(complete_plan['kept']) == expected
    release_plan = json.loads(run('retain-plan', current, source_pin, 'referrers', release_pin))
    release = directory / 'retained-release'
    run('retain-export', current, source_pin, release_plan['plan_pin'], 'referrers', release, release_pin)
    assert blob_path(release, release_pin).read_bytes() == (multi / 'index.json').read_bytes()

    # Physical source membership, even of orphan bytes, is part of review.
    new_orphan = b'added after review'
    blob_path(current, digest(new_orphan)).write_bytes(new_orphan)
    stale_output = directory / 'stale-output'
    run('retain-export', current, source_pin, plan['plan_pin'], 'referrers', stale_output, images[0], status=5)
    assert not stale_output.exists() and not Path(str(stale_output) + '.moonoci-staging').exists()
    fresh_plan = json.loads(run('retain-plan', current, source_pin, 'referrers', images[0]))
    assert fresh_plan['plan_pin'] != plan['plan_pin']
    blob_path(current, digest(new_orphan)).write_bytes(b'corrupted orphan!')
    run('content-catalog', current, source_pin, status=5)

    # Content closure alone must not bypass semantic image verification.
    invalid = directory / 'invalid-image'
    shutil.copytree(directory / 'amd64', invalid)
    manifest = json.loads(blob_path(invalid, images[0]).read_bytes())
    bad_tar = b'not a tar layer'
    blob_path(invalid, digest(bad_tar)).write_bytes(bad_tar)
    manifest['layers'] = [dict(mediaType='application/vnd.oci.image.layer.v1.tar', digest=digest(bad_tar), size=len(bad_tar))]
    invalid_manifest = encode(manifest)
    invalid_digest = digest(invalid_manifest)
    blob_path(invalid, invalid_digest).write_bytes(invalid_manifest)
    invalid_root = json.loads((invalid / 'index.json').read_bytes())
    invalid_root['manifests'][0].update(digest=invalid_digest, size=len(invalid_manifest))
    (invalid / 'index.json').write_bytes(encode(invalid_root))
    invalid_pin = digest((invalid / 'index.json').read_bytes())
    content_plan = json.loads(run('retain-plan', invalid, invalid_pin, 'closure', invalid_digest))
    refused = directory / 'invalid-export'
    run('retain-export', invalid, invalid_pin, content_plan['plan_pin'], 'closure', refused, invalid_digest, status=4)
    assert not refused.exists()

    oras_verified = False
    if args.oras:
        oras = args.oras.resolve()
        for layout, subject, expected_refs in [(output, images[0], {attached['app']}),
                (output, attached['app'], {attached['signature-demo']}), (release, release_pin, {attached['release']})]:
            result = subprocess.check_output([str(oras), 'discover', '--oci-layout', str(layout) + '@' + subject,
                                               '--format', 'json', '--depth', '1'], text=True, encoding='utf-8', timeout=60)
            assert {d['digest'] for d in json.loads(result)['referrers']} == expected_refs
        oras_verified = True
    report = dict(schema='moonoci.retention-consumer.v1', source_blobs=len(stored), kept_blobs=len(expected),
                  source_blob_bytes=sum(stored.values()), kept_blob_bytes=sum(stored[p] for p in expected),
                  reclaimed_copy_bytes=int(plan['reclaimable_bytes']), independent_closure=True,
                  independent_store_and_review_pins=True, aliases_and_extensions_preserved=True,
                  image_consumption_verified=True, source_unchanged_by_export=True, stale_plan_refused=True,
                  weak_subject_modes=True, index_subject_preserved=True, semantic_failure_refused=True,
                  oras_discovery_verified=oras_verified, source_deletions=0)
    (directory / 'report.json').write_bytes(encode(report))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
