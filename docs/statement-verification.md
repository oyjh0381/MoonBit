# Verify in-toto Statement bindings

`artifacts.verify_statement` accepts a raw in-toto Statement v1 JSON document
up to 1 MiB. The caller supplies the expected SHA-256 subject and an exact
predicate type identifier. At least one subject must carry the expected
digest. The result records the exact input bytes' SHA-256, matched subject,
predicate type and number of subjects examined.

The parser rejects duplicate JSON keys, missing digest sets, malformed
SHA-256 values and a non-object predicate. It accepts omitted predicates and
multiple subjects, with at most 1024 subjects and 32 digest entries per
subject. Names, URIs, other digest algorithms and predicate contents are
opaque. Predicate identifiers are compared as exact strings.

This profile uses the official [Statement v1 specification](https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md)
and [DigestSet format](https://github.com/in-toto/attestation/blob/main/spec/v1/digest_set.md).
Trust in a producer, DSSE signature verification and predicate-specific checks
belong to a separate verification layer.

`artifacts.verify_statement_attachment` additionally resolves the expected
subject in a local OCI layout and checks the attachment's subject digest,
media type and size. The attachment and its single payload use the
`application/vnd.in-toto+json` media type for this raw Statement profile.

```text
moonoci statement-verify INPUT ATTACHMENT_DIGEST SUBJECT_DIGEST PREDICATE_TYPE
```

The structured result identifies the raw payload digest and records
`signatures_verified: false`. The policy fixture independently hashes a
Statement and rejects a valid OCI attachment with the wrong inner digest.

Pass both `--statement-digest DIGEST` and `--statement-predicate TYPE` to
`registry-admit` to require a particular artifact manifest alongside the
existing required attachment types. Obtain this extra digest from a trusted
release channel. The Registry listing supplies discovery only. A different
attachment, a different predicate or a different inner subject blocks output.
The structured `statement_decision` reports the requested digest and the
binding or failure code independently of the attachment presence decision.
