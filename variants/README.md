# Variants

Each folder holds a version of `l1d_victim_cache.v` (and optionally `l1d_age_matrix.v`) that replaces the file of the same name in
`rtl/opt/`. The workflow checks and times every folder in parallel and compares them. `original` is the reference (timing only).
