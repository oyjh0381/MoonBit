# Consume the release archive

`scripts/downstream_chain.py` extracts the generated Mooncakes ZIP into a new
temporary workspace and creates a separate consumer module. The workspace uses
`moon.work` to resolve the extracted source. Dependency downloads can use Moon's
existing registry cache. The development checkout supplies the harness only.

```text
moon package
python scripts/downstream_chain.py --archive _build/publish/oyjh0381-moonoci-0.3.0.zip
```

Run with MoonBit 0.10.20 and a Native C build environment. A wrapper command can
be supplied as an argv array using `--moon-command-json`. The harness calls
check and test with all four backends and warnings denied.

The downstream module composes image building, OCI attachment creation,
Statement binding, versioned policy, cached Registry graph acceptance and
explicit image projection before file evidence queries. A Native package
configures transport options through the exported API. ZIP member paths are
checked before extraction. The report records the exact release archive hash.

Running every workspace member additionally exercises the extracted library's
tests. Native test fixtures initialize their shared build parent independently
of test order. The initial clean-workspace run exposed missing fixture parent
directories and a concurrent directory-creation race. The corrected fixture
setup passed with normal parallel execution.

On Windows, the extracted source and consumer passed 185 tests per portable
backend and 195 Native tests. These include the library's 184/193 tests and the
consumer's portable/Native checks. This verifies consumption of the packaged
source before registry publication. Published-download and Linux-runner evidence
are tracked separately.
