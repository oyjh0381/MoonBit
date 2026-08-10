# Normalize layer metadata by default

MoonOCI will sort archive paths deterministically and normalize timestamps, ownership, names, and default modes unless the build specification explicitly preserves or overrides them. Preserving host metadata by default would be more literal, but it would make image digests vary across operating systems and CI workers, undermining the project's reproducible-image guarantee.
