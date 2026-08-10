# Make serialized metadata deterministic and time explicit

MoonOCI will serialize OCI JSON with fixed field ordering, sorted map-like data, compact UTF-8 encoding, and no implicit current timestamp; creation time is emitted only from an explicit value or `SOURCE_DATE_EPOCH`. OCI accepts semantically equivalent JSON encodings, but their byte differences change content digests, so deterministic bytes take precedence over preserving user key order or automatically recording build time.
