# Third-party notices

MoonOCI depends on the following open-source MoonBit packages. No source code is copied into this repository; packages are resolved by the MoonBit package manager.

| Package | Version | Repository | License | Use |
| --- | --- | --- | --- | --- |
| `moonbitlang/x` | 0.5.5 | https://github.com/moonbitlang/x | Apache-2.0 | SHA-256, time and Base64 utilities |
| `hustcer/fzip` | 0.8.8 | https://github.com/hustcer/fzip | Apache-2.0 | deterministic gzip and bounded decompression |
| `moonbitlang/async` | 0.20.6 | https://github.com/moonbitlang/async | Apache-2.0 | Native filesystem and stdio integration |
| `moonbitlang/quickcheck` | 0.15.1 | https://github.com/moonbitlang/quickcheck | Apache-2.0 | property-based tests |

Each dependency's license and copyright notices remain available in its distributed package and upstream repository.

## Development-only artifact interoperability tools

ORAS 1.3.6 (Apache-2.0, https://github.com/oras-project/oras) is downloaded from
official releases only as a development-time independent client. Pinned archive
checksums are in scripts/setup_oras.py; binaries and their release archives remain
under ignored build/local-tool directories and are not redistributed in Mooncakes.
No ORAS implementation was copied into the MoonBit library. The illustrative
artifact documents and consumer adapters are original project fixtures; they do
not claim full SPDX/in-toto semantic validation or signed provenance.
