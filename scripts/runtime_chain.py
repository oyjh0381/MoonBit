"""Linux end-to-end consumer: MoonOCI packages its own verifier and runs it.
Requires moon, cc, ldd, skopeo, podman. No remote registry or base image needed.
"""
import hashlib
import argparse
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*arguments):
    try:
        result = subprocess.run(list(map(str, arguments)), cwd=ROOT, capture_output=True, text=True, timeout=240)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError((arguments, 'timeout', error.stdout, error.stderr)) from error
    if result.returncode:
        raise RuntimeError((arguments, result.returncode, result.stdout, result.stderr))
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rootful', action='store_true', help='run isolated Podman storage through sudo')
    args = parser.parse_args()
    if platform.system() != 'Linux':
        raise SystemExit('Run this chain on a Linux runner; independent_layout.py runs on Windows too.')
    for tool in ('moon', 'ldd', 'skopeo', 'podman'):
        if not shutil.which(tool):
            raise SystemExit('Required tool missing: ' + tool)
    run('moon', 'build', '--target', 'native', '--release', '--deny-warn')
    binaries = [p for p in (ROOT / '_build/native/release/build').rglob('moonoci.exe') if p.is_file()]
    if not binaries:
        raise RuntimeError('Native MoonOCI executable missing')
    binary = max(binaries, key=lambda p: p.stat().st_mtime_ns)
    workspace = Path(tempfile.mkdtemp(prefix='runtime-', dir=ROOT / '_build'))
    rootfs = workspace / 'rootfs'
    (rootfs / 'app').mkdir(parents=True)
    shutil.copy2(binary, rootfs / 'app/moonoci')
    # Only inspect our locally compiled executable; copy loader/shared libraries
    # under their original absolute paths so no shell or base distribution is needed.
    dependencies = run('ldd', binary)
    if 'not found' in dependencies:
        raise RuntimeError('Native executable has unresolved shared libraries')
    for dependency in set(re.findall(r'(/[^\s()]+)', dependencies)):
        path = Path(dependency)
        destination = rootfs / path.relative_to('/')
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path.resolve(strict=True), destination)
    arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}[platform.machine()]
    fixture_spec = dict(schemaVersion=1, ref='fixture', platform=dict(os='linux', architecture=arch),
                        layers=[dict(source=str(ROOT / 'examples/native-build/rootfs'), compression='gzip')],
                        output=dict(layout=str(rootfs / 'fixture')))
    fixture_path = workspace / 'fixture.json'
    fixture_path.write_text(json.dumps(fixture_spec))
    run(binary, 'build', fixture_path)
    spec = dict(schemaVersion=1, ref='selfcheck', platform=dict(os='linux', architecture=arch),
                layers=[dict(source=str(rootfs), compression='gzip', metadata=dict(mode=493))],
                config=dict(user='65532:65532', entrypoint=['/app/moonoci'], cmd=['verify','/fixture']),
                output=dict(layout=str(workspace / 'image')))
    spec_path = workspace / 'image.json'
    spec_path.write_text(json.dumps(spec))
    run(binary, 'build', spec_path)
    run(binary, 'verify', workspace / 'image')
    independent = json.loads(run('python3', ROOT / 'scripts/independent_layout.py', workspace / 'image'))
    image = workspace / 'image'
    original = (image / 'index.json').read_bytes()
    spec['output']['layout'] = str(workspace / 'rebuild')
    spec_path.write_text(json.dumps(spec))
    run(binary, 'build', spec_path)
    assert original == (workspace / 'rebuild/index.json').read_bytes()
    inspected = json.loads(run('skopeo', 'inspect', 'oci:' + str(image) + ':selfcheck'))
    archive = workspace / 'image.tar'
    run(binary, 'archive', image, archive)
    tag = 'localhost/moonoci-selfcheck:' + hashlib.sha256(original).hexdigest()[:16]
    runtime_archive = workspace / 'runtime.oci.tar'
    run('skopeo', 'copy', 'oci:' + str(image) + ':selfcheck', 'oci-archive:' + str(runtime_archive) + ':' + tag)
    # containers/storage limits runroot to 50 characters. Hosted checkout paths
    # are longer, so runtime state gets its own short OS temporary directory.
    runtime_state = Path(tempfile.mkdtemp(prefix='moci-'))
    podman = (['sudo'] if args.rootful else []) + [
        'podman', '--root', str(runtime_state / 'store'),
        '--runroot', str(runtime_state / 'run'), '--storage-driver', 'vfs',
        '--events-backend', 'file', '--cgroup-manager', 'cgroupfs',
    ]
    run(*podman, 'load', '--input', runtime_archive)
    # Keep an init process at PID 1 so the async CLI has ordinary process
    # shutdown semantics inside the container.
    probe = run(*podman, 'run', '--init', '-d', '--pull=never', '--timeout=15',
                '--cgroups=disabled', '--log-driver=k8s-file', '--network=none',
                '--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges',
                tag, 'version')
    pid = run(*podman, 'inspect', '--format', '{{.State.Pid}}', probe)
    children = run('ps', '--ppid', pid, '-o', 'pid=').split()
    processes = [pid] + children
    print('runtime-probe-threads', run('ps', '-T', '-p', ','.join(processes), '-o', 'pid,tid,stat,wchan,comm'), flush=True)
    trace = workspace / 'startup.strace'
    attach = [argument for process in processes for argument in ['-p', process]]
    subprocess.run(['sudo', 'timeout', '-s', 'INT', '3', 'strace', '-f', '-tt', *attach, '-o', str(trace)], capture_output=True, timeout=10)
    if trace.exists():
        print('runtime-probe-strace', trace.read_text()[-16000:], flush=True)
    print('runtime-probe-stdout', run(*podman, 'logs', probe), flush=True)
    run(*podman, 'rm', '-f', probe)
    startup = run(*podman, 'run', '--init', '--rm', '--pull=never', '--timeout=15',
                  '--cgroups=disabled', '--network=none', '--read-only', '--cap-drop=ALL',
                  '--security-opt=no-new-privileges', tag, 'version')
    assert startup.startswith('moonoci 0.2.0')
    output = run(*podman, '--log-level=debug', 'run', '--init', '--rm', '--pull=never',
                 '--timeout=60', '--cgroups=disabled', '--network=none', '--read-only', '--cap-drop=ALL',
                 '--security-opt=no-new-privileges', tag)
    assert output.startswith('valid: manifests=1')
    assert inspected['Digest'] == independent['images'][0]['manifest']
    report = dict(schema='moonoci.runtime.v1', linux=platform.platform(), architecture=arch,
                  manifest=independent['images'][0]['manifest'], skopeo_digest=inspected['Digest'],
                  runtime_output=output, reproducible=True, image_archive_bytes=archive.stat().st_size,
                  tools={tool: run(tool, '--version') for tool in ('skopeo','podman')})
    (workspace / 'runtime-report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
