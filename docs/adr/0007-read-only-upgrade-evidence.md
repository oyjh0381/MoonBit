# Keep version review read-only and bind approval to exact images

Final-file provenance and comparisons reuse the existing layer transition engine;
they observe changes without generating changesets, preserving ADR-0004's explicit
build inputs. Upgrade decisions recompute observations from verified root manifests
and require pins for both versions, so an approved path cannot silently authorize
a different candidate. Configuration output names changed fields without echoing
environment values. Host identity, trusted pins and actual runtime compatibility
remain outside this library decision.
