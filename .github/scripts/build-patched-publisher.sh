#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_root="${BUILD_ROOT:-$(mktemp -d -t patched-publisher.XXXXXX)}"
dist_dir="${DIST_DIR:-$PWD/dist}"
mkdir -p "$build_root" "$dist_dir"
build_root="$(cd "$build_root" && pwd)"
dist_dir="$(cd "$dist_dir" && pwd)"

# Repository overrides allow testing with local mirrors without changing the job.
publisher_upstream="${PUBLISHER_UPSTREAM_URL:-https://github.com/HL7/fhir-ig-publisher.git}"
core_upstream="${CORE_UPSTREAM_URL:-https://github.com/hapifhir/org.hl7.fhir.core.git}"
publisher_fixes="${PUBLISHER_FIXES_URL:-https://github.com/glichtner/fhir-ig-publisher.git}"
core_fixes="${CORE_FIXES_URL:-https://github.com/glichtner/org.hl7.fhir.core.git}"

prepare_repository() {
  local directory=$1 upstream=$2 fixes=$3
  shift 3
  if [[ -e "$directory/.git" ]]; then
    echo "Build directory already contains a checkout: $directory; use a fresh BUILD_ROOT." >&2
    return 1
  fi
  # Full commit history is required to merge independent branches correctly.
  git clone --filter=blob:none --single-branch --branch master --no-checkout \
    --origin upstream "$upstream" "$directory"
  git -C "$directory" config user.name 'Patched Publisher build'
  git -C "$directory" config user.email 'github-actions[bot]@users.noreply.github.com'
  git -C "$directory" remote add fixes "$fixes"
  git -C "$directory" checkout --quiet -b patched-build refs/remotes/upstream/master
  local branch
  for branch in "$@"; do
    git -C "$directory" fetch --no-tags --filter=blob:none fixes \
      "+refs/heads/$branch:refs/remotes/fixes/$branch"
    # Never guess a conflict resolution. Any conflict fails before publication.
    git -C "$directory" merge --no-ff --no-edit "refs/remotes/fixes/$branch"
  done
}

prepare_repository "$build_root/core" "$core_upstream" "$core_fixes" \
  fix/sliced-datatype-snapshot-recursion fix/reslicing-before-inherited-siblings
prepare_repository "$build_root/publisher" "$publisher_upstream" "$publisher_fixes" \
  fix/additional-resources-from-dependencies

if [[ "${1:-}" == --prepare-only ]]; then
  echo "Combined source checkouts prepared in $build_root"
  exit 0
fi
if [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--prepare-only]" >&2
  exit 2
fi

maven=(mvn --batch-mode --no-transfer-progress -Dstyle.color=never)
if [[ -n "${MAVEN_REPO_LOCAL:-}" ]]; then
  maven+=("-Dmaven.repo.local=$MAVEN_REPO_LOCAL")
fi

cd "$build_root/core"
# Build only modules needed by the Publisher and their reactor dependencies.
# Run the fix regressions and neighboring R6 profile tests in that same reactor.
"${maven[@]}" -pl org.hl7.fhir.validation,org.hl7.fhir.standalone -am \
  '-Dtest=org.hl7.fhir.conformance.profile.ProfileUtilities*Test,org.hl7.fhir.test.SnapShotGenerationTests' \
  -Dsurefire.failIfNoSpecifiedTests=false install
core_version="$(python3 -c 'import xml.etree.ElementTree as E; print(E.parse("pom.xml").getroot().find("{*}version").text)')"

cd "$build_root/publisher"
# Without this override Maven would use the upstream POM's released Core version.
"${maven[@]}" "-Dcore_version=$core_version" \
  -Dtest=PublisherIGLoaderAdditionalResourcesTest \
  -Dsurefire.failIfNoSpecifiedTests=false package

python3 "$script_dir/verify-patched-publisher.py" "$build_root" "$dist_dir"
java -jar "$dist_dir/publisher.jar" -v
cd "$dist_dir"
sha256sum publisher.jar > publisher.jar.sha256
