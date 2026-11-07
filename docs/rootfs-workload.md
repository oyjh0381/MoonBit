# Final filesystem observation at scale

Root filesystem transition processing indexes live entries by path segments.
Whiteouts remove the affected subtree and opaque directories clear their
children. A regular file or symlink replaces its whole prior subtree.
Adding a child checks each existing ancestor, including symlink parents.
Implicit directories are internal nodes and are omitted from the returned
inventory. Results remain sorted by UTF-8 path.

The former implementation repeatedly filtered the entire entry array and
scanned it for every parent. With N live entries and A additions this can
perform O(N × A) entry comparisons even for shallow paths. The indexed version
builds the tree once per layer and uses expected hash-map lookup per path
segment. For S total segments traversed and N surviving entries, the main
work is O(S + N log N), excluding payload hashing and treating path comparison
as bounded. Transition sorting adds O(A log A) and sorts whiteout lists.
Memory adds O(S) nodes in the worst case. A layer with many deep distinct
paths can trade more memory for fewer scans. This is an in-memory observer.

```text
python scripts/rootfs_benchmark.py --binary <moonoci> --baseline <prior-moonoci>
```

The harness creates two OCI layers with Python's USTAR writer, applies a
whiteout and file replacement, and independently verifies every final path,
content digest and contributing layer. It requires byte-identical old and new
inventory output. Three end-to-end Windows Native Debug runs per size gave
median times of 406.4 → 384.7 ms for 1,000 files and 1,840.0 → 1,548.6 ms for
4,000 files. These timings include process startup, IO, validation and JSON
output, and characterize this synthetic workload on one machine.
