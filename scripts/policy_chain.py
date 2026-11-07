"""Mixed-layout release gate consumer; validates metadata, does not run a container."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True, type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = Path(tempfile.mkdtemp(prefix='policy-', dir=ROOT / '_build'))

    def run(*arguments, status=0):
        result = subprocess.run([str(binary), *map(str, arguments)], cwd=ROOT,
                                capture_output=True, text=True, encoding='utf-8', timeout=120)
        if result.returncode != status:
            raise AssertionError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout

    source = directory / 'rootfs'
    source.mkdir()
    (source / 'app').write_bytes(b'policy fixture')
    for name, arch, user in [('amd64', 'amd64', '65532'), ('arm64', 'arm64', '65532'), ('root-arm64', 'arm64', '0')]:
        spec = dict(schemaVersion=1, ref=name, platform=dict(os='linux', architecture=arch),
                    config=dict(user=user, cmd=['/app'], env={'DEMO_TOKEN': 'fixture-value-not-for-findings'}), layers=[dict(source=str(source))],
                    output=dict(layout=str(directory / name)))
        path = directory / (name + '.json')
        path.write_text(json.dumps(spec), 'utf-8')
        run('build', path)
    run('merge', directory / 'good', directory / 'amd64', directory / 'arm64')
    run('merge', directory / 'bad', directory / 'amd64', directory / 'root-arm64')
    subject = json.loads((directory / 'amd64/index.json').read_bytes())['manifests'][0]['digest']
    payload = directory / 'sbom.json'
    payload.write_bytes(b'{"fixture":"not-a-full-SBOM"}')
    for name, expected in [('good', 0), ('bad', 5)]:
        output = directory / (name + '-attached')
        artifact = run('artifact-attach', directory / name, subject, 'application/spdx+json',
                       'application/json', payload, 'proof', output).strip()
        before = (output / 'index.json').read_bytes()
        decision = json.loads(run('gate-store', output, status=expected))
        assert decision['allowed'] == (expected == 0)
        assert decision['store']['valid'] and decision['store']['artifacts_checked'] == 1
        assert decision['images']['manifests_checked'] == 2
        assert (output / 'index.json').read_bytes() == before
        if expected:
            assert any(item['code'] == 'nonroot-user-required' for item in decision['images']['findings'])
        else:
            only = directory / 'artifact-only'
            run('artifact-export', output, artifact, only)
            denied = json.loads(run('gate-store', only, status=5))
            assert denied['store']['valid'] and not denied['allowed']
            assert any(item['code'] == 'empty-distribution' for item in denied['images']['findings'])
    report = dict(schema='moonoci.mixed-policy-consumer.v1', all_platforms_checked=True,
                  valid_attachments_retained=True, bad_secondary_platform_blocks=True,
                  artifact_only_blocks=True, source_unchanged=True, container_runtime_executed=False)
    for name, rules, source_name, status, expected_code in [
        ('no-root-check', {'requireNumericNonroot': False}, 'bad-attached', 0, None),
        ('only-amd64', {'allowedPlatforms': [{'os': 'linux', 'architecture': 'amd64'}]}, 'good-attached', 5, 'platform-not-allowed'),
        ('required-team', {'requiredLabels': ['team']}, 'good-attached', 5, 'required-label'),
        ('forbidden-token', {'forbiddenEnvNames': ['DEMO_TOKEN']}, 'good-attached', 5, 'forbidden-environment'),
    ]:
        path = directory / (name + '.policy.json')
        path.write_text(json.dumps({'schemaVersion': 1, **rules}), 'utf-8')
        raw = run('gate-store', directory / source_name, path, status=status)
        assert 'fixture-value-not-for-findings' not in raw
        decision = json.loads(raw)
        assert decision['allowed'] == (status == 0)
        if expected_code:
            assert any(item['code'] == expected_code for item in decision['images']['findings'])
    invalid = directory / 'invalid.policy.json'
    invalid.write_bytes(b'{"schemaVersion":1,"typo":false}')
    run('gate-store', directory / 'good-attached', invalid, status=2)
    invalid.write_bytes(b' ' * 65537)
    run('gate-store', directory / 'good-attached', invalid, status=5)
    report.update(versioned_policy_files=True, environment_values_not_echoed=True, oversized_policy_refused=True)
    (directory / 'report.json').write_text(json.dumps(report, indent=2), 'utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
