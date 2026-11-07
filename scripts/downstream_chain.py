"""Consume the release ZIP in an isolated MoonBit workspace through public APIs."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
CONSUMER = r'''
///|
pub fn verify_consumer() -> Unit raise {
  let image = @builder.build_single_layer(
    @builder.default_single_layer_request([
      @archive.TarEntry::file("app", b"consumer"),
    ]),
  )
  let subject = image.report.manifest
  let statement = @utf8.encode(
    "{\"_type\":\"https://in-toto.io/Statement/v1\",\"predicateType\":\"urn:consumer:build\",\"subject\":[{\"digest\":{\"sha256\":\"" +
    subject.digest.encoded + "\"}}]}",
  )
  let artifact = @artifacts.attach(
    image.layout,
    subject,
    @artifacts.statement_media_type,
    [{
      media_type: @artifacts.statement_media_type,
      data: statement,
      annotations: [],
    }],
  )
  let binding = @artifacts.verify_statement_attachment(
    artifact.layout, artifact.descriptor, subject.digest, "urn:consumer:build",
  )
  assert_eq(binding.payload, @digest.sha256(statement))
  let policy = @policy.decode_release_policy(
    b"{\"schemaVersion\":1,\"requireNumericNonroot\":false,\"requireCommand\":false}",
  )
  assert_true(@policy.evaluate_mixed(artifact.layout, policy~).allowed)
  let pin = @digest.sha256(artifact.layout.index())
  let pull = @registry.PullSession::new("team/app", "release", pin)
  while pull.next() is Some(request) {
    let body = if request.digest == pin {
      artifact.layout.index()
    } else {
      artifact.layout.get_blob(request.digest).unwrap()
    }
    pull.accept_cached(body)
  }
  let rebuilt = pull.finish()
  assert_eq(rebuilt.index(), artifact.layout.index())
  assert_eq(pull.accepted_network_bytes(), 0L)
  assert_true(pull.is_verified())
  assert_eq(
    @builder.inventory_from_manifest(
      @graph.flatten_images(rebuilt, allow_skipped=true), subject,
    )[0].content_digest,
    Some(@digest.sha256(b"consumer")),
  )
}
'''
NATIVE = r'''
///|
pub fn verify_transport() -> Unit raise {
  let options : @remote.RegistryOptions = {
    ..@remote.RegistryOptions::default(),
    max_http_requests: 8,
    max_retries: 0,
    proxy_origin: Some("http://127.0.0.1:3128"),
  }
  options.validate()
  let invalid = { ..options, max_http_requests: 0 }
  let rejected = try {
    invalid.validate()
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--moon-command-json', default='["moon"]',
                        help='JSON argv prefix, for example a compiler environment wrapper')
    args = parser.parse_args()
    command = json.loads(args.moon_command_json)
    if not isinstance(command, list) or not command or not all(isinstance(v, str) for v in command):
        parser.error('moon-command-json must be a nonempty argv array')
    archive = args.archive.resolve()
    work = Path(tempfile.mkdtemp(prefix='downstream-', dir=ROOT / '_build'))
    library = work / 'library'
    library.mkdir()
    with ZipFile(archive) as release:
        for name in release.namelist():
            relative = PurePosixPath(name)
            if relative.is_absolute() or '..' in relative.parts or '\\' in name or ':' in name:
                raise ValueError('unsafe ZIP member')
            if {'.private', '_build', '.mooncakes'} & set(relative.parts):
                raise ValueError('private/build content in release')
        release.extractall(library)
    consumer = work / 'consumer'
    consumer.mkdir()
    (work / 'moon.work').write_text('members = ["library", "consumer"]\n', encoding='utf-8')
    (consumer / 'moon.mod').write_text(
        'name = "validation/downstream"\nimport { "oyjh0381/moonoci@0.2.0" }\n', encoding='utf-8')
    imports = ['archive', 'builder', 'artifacts', 'digest', 'policy', 'registry', 'graph']
    (consumer / 'moon.pkg').write_text('import {\n' +
        ''.join(f'  "oyjh0381/moonoci/{name}",\n' for name in imports) +
        '  "moonbitlang/core/encoding/utf8",\n}\n', encoding='utf-8')
    (consumer / 'consumer.mbt').write_text(CONSUMER, encoding='utf-8')
    (consumer / 'consumer_wbtest.mbt').write_text(
        'test "public consumer composes" { verify_consumer() }\n', encoding='utf-8')
    native = consumer / 'native'
    native.mkdir()
    (native / 'moon.pkg').write_text(
        'import { "oyjh0381/moonoci/adapter/remote" }\nsupported_targets = "+native"\n',
        encoding='utf-8')
    (native / 'consumer.mbt').write_text(NATIVE, encoding='utf-8')
    (native / 'consumer_wbtest.mbt').write_text(
        'test "Native consumer configures transport" { verify_transport() }\n', encoding='utf-8')
    for arguments in [('check', '--target', 'all', '--deny-warn'),
                      ('test', '--target', 'all', '--deny-warn')]:
        result = subprocess.run([*command, *arguments], cwd=consumer, capture_output=True,
                                text=True, encoding='utf-8', timeout=300)
        (work / (arguments[0] + '.log')).write_text(result.stdout + result.stderr, encoding='utf-8')
        if result.returncode:
            raise RuntimeError((arguments, result.returncode, result.stdout, result.stderr))
        print(result.stdout.strip())
    report = dict(schema='moonoci.downstream-consumer.v1',
                  release_sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                  isolated_workspace=True, extracted_release_source=True,
                  source_repository_used_as_dependency=False,
                  portable_public_api_composition=True,
                  native_transport_options=True, backends=['wasm', 'wasm-gc', 'js', 'native'])
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
