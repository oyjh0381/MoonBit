# Multi-platform rollout review

`moonoci rollout-check BASE CANDIDATE POLICY_JSON` checks exact platform
coverage in two OCI layouts, including nested indexes. Both index digests
come from the caller's reviewed policy. The command checks the selected
images' layer bytes and DiffIDs before comparing final files and runtime
configuration. An identical manifest digest still requires valid content
in both layouts.

```json
{
  "schemaVersion": 1,
  "baselineIndex": "<trusted baseline index digest>",
  "candidateIndex": "<trusted candidate index digest>",
  "requiredPlatforms": [
    {"os": "linux", "architecture": "amd64"},
    {"os": "linux", "architecture": "arm64", "variant": "v8"}
  ],
  "approvals": [
    {
      "platform": {"os": "linux", "architecture": "amd64"},
      "baselineManifest": "<reviewed baseline amd64 manifest digest>",
      "candidateManifest": "<reviewed candidate amd64 manifest digest>",
      "paths": ["app"],
      "fields": ["config.Env"]
    }
  ]
}
```

Replace the four placeholders with SHA-256 digests. Omit approvals for an
initial review. Each entry applies only to its exact platform and selected
manifest pair. OS, architecture, variant and OS version are exact matches.
`allowNewPlatforms` allows verified new required platforms and defaults to
false. An approval's `allowAdditions` permits added paths and defaults to
false. Removed required platforms, ambiguity and unknown media block the
decision. Known non-image manifests are outside the image policy.

The JSON result reports the two source digests, transitions, file change counts
and pending path and field names. The exit status is 0 for an allowed decision
and 5 for a blocked decision. Invalid documents or corrupt input produce a
structured CLI error. Review covers observed file and configuration changes.
Runtime compatibility and external dependencies require separate validation.

```text
moon build --target native --deny-warn
python scripts/rollout_chain.py --binary _build/native/debug/build/cmd/moonoci/moonoci.exe
```

The consumer independently computes index, manifest and file evidence for a
nested baseline and two platforms. It checks that exact approval unblocks the
changed image and that missing platforms, ambiguity and stale approvals fail.
