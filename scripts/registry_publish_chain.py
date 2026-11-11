"""Exercise reviewed OCI publication, interrupted writes and independent readback."""
import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from urllib.parse import parse_qs, urlsplit
from urllib.request import urlopen

from registry_chain import INDEX, MANIFEST, ROOT, encode, pin, serve

REPO = "team/release"
PREFIX = "/v2/" + REPO
UPLOAD = PREFIX + "/blobs/uploads/"


def build_layout(run, work):
    filesystem = work / "rootfs"
    filesystem.mkdir()
    (filesystem / "data").write_bytes(b"shared layer\n")
    platforms = []
    for architecture in ("amd64", "arm64"):
        output = work / architecture
        spec = work / (architecture + ".json")
        spec.write_bytes(encode(dict(schemaVersion=1, ref=architecture,
            platform=dict(os="linux", architecture=architecture),
            layers=[dict(source=str(filesystem), compression="none")],
            output=dict(layout=str(output)))))
        run("build", spec)
        platforms.append(output)
    multi = work / "multi"
    run("merge", multi, *platforms)
    nested_bytes = (multi / "index.json").read_bytes()
    nested_pin = pin(nested_bytes)
    (multi / "blobs/sha256" / nested_pin[7:]).write_bytes(nested_bytes)
    outer = encode(dict(schemaVersion=2, mediaType=INDEX, manifests=[dict(
        mediaType=INDEX, digest=nested_pin, size=len(nested_bytes),
        annotations={"org.opencontainers.image.ref.name": "candidate"},
    )]))
    (multi / "index.json").write_bytes(outer)
    return multi, pin(outer), nested_pin


def fixture():
    state = dict(blobs={}, manifests={}, tags={}, sessions=set(), requests=[],
                 next_session=0, failed=False, successful_blobs=0, corrupt_readback=False)

    class Registry(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def reply(self, status, body=b"", media=None, digest=None, location=None):
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            if media:
                self.send_header("Content-Type", media)
            if digest:
                self.send_header("Docker-Content-Digest", digest)
            if location:
                self.send_header("Location", location)
            self.end_headers()
            self.close_connection = True
            if self.command != "HEAD":
                self.wfile.write(body)

        def observe_request(self):
            url = urlsplit(self.path)
            state["requests"].append((self.command, url.path))
            assert self.headers.get("Authorization") is None
            return url

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            path = self.observe_request().path
            if path.startswith(PREFIX + "/blobs/"):
                digest = path.split("/")[-1]
                if digest in state["blobs"]:
                    self.reply(200, state["blobs"][digest], "application/octet-stream", digest)
                    return
            if path.startswith(PREFIX + "/manifests/"):
                reference = path.split("/")[-1]
                digest = state["tags"].get(reference, reference)
                if digest in state["manifests"]:
                    media, body = state["manifests"][digest]
                    if self.command == "GET" and reference == "stable" and state["corrupt_readback"]:
                        body = body[:-1] + b" "
                    self.reply(200, body, media, digest)
                    return
            self.reply(404)

        def do_POST(self):
            assert self.observe_request().path == UPLOAD
            assert self.headers["Content-Length"] == "0"
            state["next_session"] += 1
            session = "session-" + str(state["next_session"])
            state["sessions"].add(session)
            self.reply(202, location=UPLOAD + session + "?_state=opaque%3D")

        def do_PUT(self):
            url = self.observe_request()
            length = int(self.headers["Content-Length"])
            assert 0 < length <= 1024 * 1024
            body = self.rfile.read(length)
            assert len(body) == length
            digest = pin(body)
            if url.path.startswith(UPLOAD):
                session = url.path.removeprefix(UPLOAD)
                assert session in state["sessions"]
                assert parse_qs(url.query) == {"_state": ["opaque="], "digest": [digest]}
                assert self.headers["Content-Type"] == "application/octet-stream"
                if state["successful_blobs"] == 1 and not state["failed"]:
                    state["failed"] = True
                    self.reply(503)
                    return
                state["sessions"].remove(session)
                state["blobs"][digest] = body
                state["successful_blobs"] += 1
                self.reply(201, digest=digest, location=PREFIX + "/blobs/" + digest)
                return
            assert url.path.startswith(PREFIX + "/manifests/")
            ref = url.path.split("/")[-1]
            media = self.headers["Content-Type"]
            document = json.loads(body)
            if media == INDEX:
                assert all(child["digest"] in state["manifests"] for child in document["manifests"])
            else:
                assert media == MANIFEST
                assert all(child["digest"] in state["blobs"]
                           for child in [document["config"], *document["layers"]])
            state["manifests"][digest] = (media, body)
            if ref.startswith("sha256:"):
                assert ref == digest
            else:
                state["tags"][ref] = digest
            self.reply(201, digest=digest, location=PREFIX + "/manifests/" + digest)

    return Registry, state


def loopback_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@contextmanager
def run_zot(executable, directory):
    port = loopback_port()
    settings = directory / "zot.json"
    settings.write_bytes(encode(dict(
        distSpecVersion="1.1.1",
        storage=dict(rootDirectory=str(directory / "zot-store"), gc=False, dedupe=False),
        http=dict(address="127.0.0.1", port=str(port)),
    )))
    with run_loopback_registry([executable, "serve", settings], directory / "zot.log", port) as origin:
        yield origin


@contextmanager
def run_loopback_registry(command, log_path, port):
    origin = f"http://127.0.0.1:{port}"
    with log_path.open("wb") as log:
        server = subprocess.Popen(list(map(str, command)), cwd=log_path.parent,
            stdout=log, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        try:
            for _ in range(100):
                if server.poll() is not None:
                    break
                try:
                    with urlopen(origin + "/v2/", timeout=0.25) as response:
                        if response.status == 200:
                            break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError(f"Registry did not become ready; see {log_path}")
            if server.poll() is not None:
                raise RuntimeError(f"Registry exited; see {log_path}")
            yield origin
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait(timeout=8)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--oras", type=Path, required=True)
    parser.add_argument("--zot", type=Path)
    args = parser.parse_args()
    binary, oras = args.binary.resolve(strict=True), args.oras.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix="registry-publish-", dir=ROOT / "_build"))
    environment = os.environ.copy()
    for key in ("MOONOCI_REGISTRY_PUSH_TOKEN", "MOONOCI_REGISTRY_TOKEN"):
        environment.pop(key, None)
    auth = work / "empty-auth.json"
    auth.write_bytes(b"{}")

    def command(executable, *arguments, status=0, extra_env=None):
        result = subprocess.run([str(executable), *map(str, arguments)], cwd=work,
            env={**environment, **(extra_env or {})}, text=True, encoding="utf-8",
            capture_output=True, timeout=90)
        if result.returncode != status:
            raise RuntimeError((arguments, result.returncode, result.stdout, result.stderr))
        return result.stdout.strip()

    def run(*arguments, **kwargs):
        return command(binary, *arguments, **kwargs)

    layout, index_pin, root_pin = build_layout(run, work)
    expected = {path.name: path.read_bytes() for path in (layout / "blobs/sha256").iterdir()}

    def exercise(origin, label, state=None):
        params = (layout, index_pin, "candidate", origin, REPO, "stable")
        plan = json.loads(run("registry-plan", *params, "--allow-http"))
        assert plan["root"] == root_pin
        assert len(plan["blobs"]) == 3 and len(plan["manifests"]) == 3
        execute = ("registry-publish", *params, plan["plan_pin"], "--allow-http")
        if state is not None:
            run("registry-publish", *params, pin(b"wrong approval"), "--allow-http", status=5)
            run(*execute, status=2, extra_env={"MOONOCI_REGISTRY_PUSH_TOKEN": "fixture-token"})
            assert not state["requests"]
            run(*execute, status=3)
            assert state["failed"] and len(state["blobs"]) == 1 and not state["tags"]
        receipt = json.loads(run(*execute))
        assert receipt["root"] == root_pin and receipt["tag_written"]
        assert receipt["uploaded_blobs"] == (2 if state is not None else 3)
        assert receipt["reused_blobs"] == (1 if state is not None else 0)
        assert receipt["uploaded_manifests"] == 2
        retry = json.loads(run(*execute))
        assert not retry["tag_written"] and retry["uploaded_bytes"] == "0"
        assert retry["reused_blobs"] == 3 and retry["reused_manifests"] == 2
        reference = origin.removeprefix("http://") + "/" + REPO + ":stable"
        output = work / label
        command(oras, "cp", "--from-plain-http", "--from-registry-config", auth,
                "--to-oci-layout", reference, str(output) + ":stable")
        found = {path.name: path.read_bytes() for path in (output / "blobs/sha256").iterdir()}
        assert found == expected
        if state is not None:
            state["corrupt_readback"] = True
            before = len(state["requests"])
            run(*execute, status=5)
            assert all(verb in ("HEAD", "GET") for verb, _ in state["requests"][before:])
            state["corrupt_readback"] = False
            state["tags"]["stable"] = plan["manifests"][0]["digest"]
            before = len(state["requests"])
            run(*execute, status=5)
            assert state["requests"][before:] == [("HEAD", PREFIX + "/manifests/stable")]
        return dict(upload=receipt, retry=retry, oras_objects=len(found))

    handler, state = fixture()
    with serve(handler) as origin:
        result = {"loopback_fixture": exercise(origin, "oracle-fixture", state)}
    if args.zot:
        with run_zot(args.zot.resolve(strict=True), work) as origin:
            result["zot"] = exercise(origin, "oracle-zot")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
