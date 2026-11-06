"""Public Native CLI consumer for content-aware release review, Windows/Linux."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from independent_layout import observe

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='upgrade-', dir=ROOT / '_build'))

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT, capture_output=True, text=True, encoding='utf-8', timeout=120)
        if result.returncode != status:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout

    base_source, patch = directory / 'base', directory / 'patch'
    for source in (base_source, patch):
        (source / 'bin').mkdir(parents=True)
        (source / 'config').mkdir()
    (base_source / 'bin/app').write_bytes(b'old')
    (base_source / 'config/obsolete').write_bytes(b'removed')
    (base_source / 'shared.bin').write_bytes(b'unchanged')
    (patch / 'bin/app').write_bytes(b'new')  # same length, different content
    (patch / 'config/runtime').write_bytes(b'new configuration')
    for version in (1, 2):
        layers = [dict(source=str(base_source), compression='gzip')]
        runtime = {}
        if version == 2:
            layers.append(dict(source=str(patch), compression='none', remove=['config/obsolete']))
            runtime = dict(user='65532:65532', entrypoint=['/bin/app'])
        spec = dict(schemaVersion=1, ref='demo', platform=dict(os='linux', architecture='amd64'),
                    layers=layers, config=runtime, output=dict(layout=str(directory / f'v{version}')))
        path = directory / f'v{version}.json'
        path.write_text(json.dumps(spec), encoding='utf-8')
        run('build', path)
    base, target = directory / 'v1', directory / 'v2'
    independent = observe(target)['images'][0]
    inventory = json.loads(run('files', target, 'linux', 'amd64'))
    for item in inventory['entries']:
        expected = independent['files'][item['path']]
        assert item['mode'] == expected['mode']
        assert int(item['bytes']) == expected['bytes']
        assert item['uid'] == expected['uid'] and item['gid'] == expected['gid']
        assert int(item['mtime']) == expected['mtime']
        assert item['layer_index'] == expected['layer_index'] and item['layer_digest'] == expected['layer_digest']
        assert item['link_target'] == expected['link_target']
        if item['kind'] == 'file':
            assert item['content_digest'] == 'sha256:' + expected['sha256']
    by_path = {item['path']: item for item in inventory['entries']}
    assert by_path['shared.bin']['layer_index'] == 0
    assert by_path['bin/app']['layer_index'] == 1
    assert 'config/obsolete' not in by_path
    changes = json.loads(run('diff', base, target, 'linux', 'amd64'))
    assert (changes['added'], changes['removed'], changes['modified']) == (1, 1, 1)
    assert next(c for c in changes['changes'] if c['path'] == 'bin/app')['content_changed']
    config = json.loads(run('config-diff', base, target, 'linux', 'amd64'))
    assert config['requires_review']
    assert {c['field'] for c in config['changes'] if c['impact'] == 'review'} == {'config.User', 'config.Entrypoint'}
    base_pin = observe(base)['images'][0]['manifest']
    target_pin = independent['manifest']
    decision = json.loads(run('upgrade-check', base, target, 'linux', 'amd64', base_pin, target_pin, status=5))
    assert not decision['allowed'] and len(decision['unreviewed_paths']) == 3
    run('upgrade-check', base, target, 'linux', 'amd64', base_pin, 'sha256:' + '0' * 64, status=5)
    # Pin binding and comparisons do not alter preserved layouts.
    assert observe(target)['images'][0]['manifest'] == target_pin
    report = dict(schema='moonoci.upgrade-consumer.v1', base_manifest=base_pin,
                  target_manifest=target_pin, added=1, removed=1, modified=1,
                  independent_content_match=True, inherited_layer_preserved=True,
                  review_required=True, wrong_pin_refused=True)
    (directory / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
