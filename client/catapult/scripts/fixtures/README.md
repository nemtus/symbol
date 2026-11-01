# Fixtures for test-runtime-staging.sh

## `catapult-needed-graph.tsv`

`<object>\t<NEEDED SONAME>`, one edge per line. **Recorded, not written by hand.**

Extracted from the `catapult-image` CI builds of 2026-10-31 (runs 41195922316 and
41213453962) by reading the `UNRESOLVED <object>: <soname> => not found` lines the
runtime link check emitted. 148 objects, 639 edges, including:

- the transitive `libmongocxx1.so.1 -> libmongoc2.so.2` / `libbsoncxx1.so.1 ->
  libbson2.so.2` edges, which nothing in `bin/` names and which an earlier one-level
  implementation therefore missed;
- catapult's own 25 `libcatapult.*` / `libextension.*` plugins, which are build outputs
  in `bin/` rather than dependencies.

Distro-provided SONAMEs (libc, libstdc++, …) are absent because they resolved and so were
never reported unresolved. The test's `ldd` stub adds one back to confirm they are not
mistakenly treated as bundled.

### Refreshing it

Only needed when upstream changes catapult's dependencies. From a failing or succeeding
`catapult-image` run's log:

```sh
gh api "repos/nemtus/symbol/actions/jobs/<JOB_ID>/logs" --allow-escape-sequences \
  | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -E 'UNRESOLVED  /opt/catapult/' \
  | sed 's/.*UNRESOLVED  //; s/ => not found//' \
  | sed 's|/opt/catapult/[a-z]*/||' \
  | awk -F': ' '{print $1"\t"$2}' | sort -u > catapult-needed-graph.tsv
```

A stale fixture makes the test weaker, never wrong: it still exercises every code path,
just against an older dependency graph. The image build remains the authority on the
current one.
