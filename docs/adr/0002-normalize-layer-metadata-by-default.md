# Normalize layer metadata by default

MoonOCI will sort archive paths deterministically and normalize timestamps, ownership, names, and default modes unless the build specification explicitly overrides them. Build Specification v1 additionally permits preserving mtime; host mode and ownership preservation are outside the v1 schema because their cross-platform meaning is not stable. Preserving host metadata by default would be more literal, but it would make image digests vary across operating systems and CI workers, undermining the project's reproducible-image guarantee.
