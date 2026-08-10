# Use declarative layer changesets instead of snapshot differencing

Each MoonOCI layer source will contain additions and modifications, while removals and opaque directories are declared explicitly and encoded as OCI whiteouts. Automatically comparing successive complete root filesystem snapshots would be convenient for some callers, but it would duplicate large trees, entangle the core with host filesystem identity rules, and make reproducibility harder to reason about.
