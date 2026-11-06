# Quarterly development programme

Target: strengthen MoonOCI with a reproducible executable consumer and broadly
reusable cloud-native capabilities. Eligibility and which dates of contribution
count remain subject to the quarterly organizer's rules. Submission volume is
not an official scoring criterion verified by this project.

The starting branch contains 12 commits. The requested total above 100 requires
at least 89 new meaningful commits; the initial increment does not achieve that
total. Preserve actual work dates and authors. No empty commits, retrospective
history fabrication, or splitting one mechanical edit into dozens of commits.

Development streams, each requiring real interfaces, adversarial cases,
integration examples, measured resource costs and maintenance documentation:

| Stream | Current increment | Further work requiring implementation |
| --- | --- | --- |
| Executable consumption | Native self-hosted verifier packaging and Linux runner | Execute CI, negative runtime cases, reproducibility across clean runners |
| Multi-platform distribution | Merge, selection, standalone slicing | Nested-index graph limits, variant fixtures, independent Skopeo selection |
| Offline delivery | Missing-blob plan, trusted index pin | Verified delta envelopes, hydration, interrupted-transfer recovery |
| Content lifecycle | Existing content-addressed store | Indexed lookup, reachability analysis, safe garbage collection, quotas |
| Release governance | Existing graph validation | Runtime-policy findings, per-platform policy, structured decision output |
| Change analysis | Existing rootfs metadata reconstruction | Content-aware tree diff, file provenance, config compatibility comparison |
| Supply-chain attachments | Not implemented | OCI artifact/referrer models, provenance binding, interoperability fixtures |
| Performance and robustness | Existing unit/property tests | Workload curves, decode limits, large graph tests, regression baselines |

Record each completed coherent implementation or validated fix as it happens.
Review commit quality and actual count at milestone boundaries. The 100+ target
is complete only when the work exists and all relevant checks pass; a roadmap
or generated list of commits is not delivery.
