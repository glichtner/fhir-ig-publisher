#!/bin/bash
#
# download-fhir-r6-ballot5.sh - Seed the local FHIR package cache with the
# R6 6.0.0-ballot5 core packages, with two fixes applied:
#
# 1. Web location: the packages published at hl7.org/fhir/6.0.0-ballot5 carry
#    the spec publisher's local build path (file:/Users/grahame/...) as their
#    web location, which turns every spec link in rendered IGs into a broken
#    file: link. Rewritten to https://hl7.org/fhir/6.0.0-ballot5/.
#
# 2. Materialized extension slicing: ballot5 snapshots carry explicit
#    url-discriminator slicing on every *.extension / *.modifierExtension
#    element (ballot4 did not). That slicing is implicit in FHIR anyway, and
#    it sends the IG Publisher's snapshot generator (ProfilePathProcessor)
#    into infinite recursion (StackOverflowError) when a profile re-slices an
#    extension. The empty materialized slicing entries are stripped; slicing
#    with actual named slices is kept.
#
# Ballot5 is not on the FHIR package registries yet, so the IG Publisher and
# SUSHI cannot resolve it on their own. Once the registries serve a fixed
# ballot5 package, this script can be retired.

set -euo pipefail

fhir_version="6.0.0-ballot5"

for p in hl7.fhir.r6.core hl7.fhir.r6.expansions; do
    dir="$HOME/.fhir/packages/${p}#${fhir_version}"
    if [ -f "$dir/package/package.json" ]; then
        echo "$p#$fhir_version already present"
        continue
    fi
    echo "Installing $p#$fhir_version from hl7.org..."
    rm -rf "$dir"
    mkdir -p "$dir"
    curl -fsSL "https://hl7.org/fhir/${fhir_version}/${p}.tgz" | tar -xz -C "$dir"
    test -f "$dir/package/package.json"

    # 1. fix web location
    grep -rlF 'file:/Users/grahame/work/r6/publish/' "$dir" 2>/dev/null | while IFS= read -r f; do
        sed -i "s|file:/Users/grahame/work/r6/publish/|https://hl7.org/fhir/${fhir_version}/|g" "$f"
    done || true

    # 2. strip materialized extension slicing
    python3 - "$dir/package" <<'PYEOF'
import json, glob, sys
base = sys.argv[1]
changed_files = 0
removed = 0
for f in glob.glob(base + "/StructureDefinition-*.json"):
    try:
        j = json.load(open(f, encoding="utf-8"))
    except Exception:
        continue
    if j.get("resourceType") != "StructureDefinition":
        continue
    file_changed = False
    for part in ("snapshot", "differential"):
        els = j.get(part, {}).get("element", [])
        with_names = {e["path"] for e in els if e.get("sliceName")}
        for e in els:
            p = e.get("path", "")
            if (p.endswith(".extension") or p.endswith(".modifierExtension")) \
                    and "slicing" in e and p not in with_names:
                del e["slicing"]
                removed += 1
                file_changed = True
    if file_changed:
        json.dump(j, open(f, "w", encoding="utf-8"), indent=2)
        changed_files += 1
print(f"normalized {changed_files} files, removed {removed} materialized slicing entries")
PYEOF
done
