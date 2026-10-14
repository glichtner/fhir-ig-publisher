# Daily Publisher for AWMF and EBM

The `Patched Publisher nightly` workflow builds current `master` from
`HL7/fhir-ig-publisher` and `hapifhir/org.hl7.fhir.core`, including these branches:

| Repository in the glichtner account | Branch |
| --- | --- |
| fhir-ig-publisher | fix/additional-resources-from-dependencies |
| org.hl7.fhir.core | fix/sliced-datatype-snapshot-recursion |
| org.hl7.fhir.core | fix/reslicing-before-inherited-siblings |

Both independent Core branches are merged into a fresh upstream checkout. The
Publisher fix is merged into a separate fresh upstream checkout. These merges
exist only on the runner: the workflow never pushes source branches or changes
the fix branches. Conflicts stop the build for manual resolution.

The job installs the required Core modules and runs both Core regressions plus
neighboring R6 profile/snapshot tests. It then builds the executable Publisher
with `-Dcore_version=<the Core version just built>` and runs the Publisher
regression. Before publishing, it checks that all three regression classes ran
successfully and that the two changed production classes in the fat JAR are
byte-for-byte identical to the tested classes.

Each successful run uploads `publisher.jar`, `publisher.jar.sha256`, and
`build-info.json` to a new release. Metadata records both upstream SHAs and all
three fix-branch SHAs. Assets are uploaded to a draft first; only then is the
release published and marked latest. A failed build or upload leaves the
previous successful download available. These are custom builds, not official
HL7 releases. Release tags point at the automation commit; the source inputs are
recorded in `build-info.json`.

Stable download after the first successful run:

```text
https://github.com/glichtner/fhir-ig-publisher/releases/latest/download/publisher.jar
```

## Activation

1. Merge this workflow and its two scripts into `master` in
   `glichtner/fhir-ig-publisher`, the fork's default branch.
2. Enable Actions in the fork if needed. No personal access token is required:
   the release job uses the repository's `GITHUB_TOKEN` with `contents: write`.
3. Run `Patched Publisher nightly` manually once and check the first release.
4. Use the updated `download-publisher.sh` and `build-snapshot1` in AWMF and EBM.

The daily schedule is 03:23 UTC (04:23 CET / 05:23 CEST). GitHub schedules run
from the default branch, may be delayed, and can be disabled after 60 days of
inactivity in public repositories. A manual trigger is also available.

## Consumer builds

Both IG helpers resolve `releases/latest` once, then fetch the checksum and JAR
from that exact release tag. This avoids mixing assets from different builds.
They verify SHA-256 before replacing an existing JAR, and reuse a matching JAR.
No sibling Publisher/Core checkout, `javac`, patch file, or Lombok download is
needed. Existing JDK, SUSHI, and Jekyll requirements still apply.

```bash
cd ebm
./build-snapshot1 --incubator
./build-snapshot1
cd ../awmf-ig
./build-snapshot1
```

To keep all builds on one exact tool version, set the same `PUBLISHER_TAG` to an
existing `patched-...` release tag in both repositories. For an offline build,
set `PUBLISHER_OFFLINE=1`; this requires a previously verified local JAR and its
`input-cache/publisher.jar.sha256`. Downloads fail explicitly when no release is
available, rather than running an old unpatched Publisher.

The intermediate-profile workaround in AWMF's
`p-guideline-registry-record.fsh` is retained. Removing it is a separate IG change
after confirming the new runtime in a full IG build.

## Local build

Use JDK 17, Maven, Git, Python 3, and `sha256sum`:

```bash
BUILD_ROOT=/tmp/my-patched-publisher DIST_DIR="$PWD/dist" \
  bash .github/scripts/build-patched-publisher.sh
```

Use a fresh `BUILD_ROOT` each time. `--prepare-only` stops after fetching and
merging all inputs. `MAVEN_REPO_LOCAL` optionally selects an isolated Maven cache.
`PUBLISHER_UPSTREAM_URL`, `CORE_UPSTREAM_URL`, `PUBLISHER_FIXES_URL`, and
`CORE_FIXES_URL` can point to local Git mirrors for testing.

After upstream accepts a fix, verify its regression on the new upstream and
remove that branch from the build script and provenance checks. Keep the tests
or equivalent coverage; a source refactor may require updating the JAR class
checks. Until then, an upstream merge conflict intentionally blocks new releases.
