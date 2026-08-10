# Release checklist

MoonOCI is prepared for publication but this repository does not publish automatically.

1. Confirm the version and changelog.
2. Run `moon fmt --check` and `moon check --target all --deny-warn`.
3. Run `moon test --target wasm-gc --deny-warn`.
4. Run `moon test --target native --deny-warn` in a configured Native compiler environment.
5. Run all three portable examples and the Native build example.
6. Verify the generated layout with MoonOCI and Skopeo.
7. After `moon login`, run `moon publish --dry-run` and inspect the package file list. Current Moon versions require credentials even for dry-run.
8. Confirm `LICENSE` and `THIRD_PARTY_NOTICES.md`.
9. Tag the reviewed commit.
10. Only after explicit maintainer approval, run `moon publish` and create the release record.

Publication credentials must never be stored in the repository.
