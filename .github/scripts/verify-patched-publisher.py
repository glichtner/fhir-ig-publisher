"""Verify the tested classes are in the fat JAR and record the source commits."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone

root, dist = map(Path, sys.argv[1:])
publisher = root / "publisher"
core = root / "core"


def revision(repo, ref):
    return subprocess.check_output(["git", "-C", str(repo), "rev-parse", ref], text=True).strip()


def require_tests(repo, module, names):
    for name in names:
        report = repo / module / "target/surefire-reports" / f"TEST-{name}.xml"
        suite = ET.parse(report).getroot()
        assert int(suite.get("tests", "0")) > 0, f"No tests executed: {name}"
        assert all(int(suite.get(key, "0")) == 0 for key in ("failures", "errors", "skipped")), name


require_tests(core, "org.hl7.fhir.standalone", [
    "org.hl7.fhir.conformance.profile.ProfileUtilitiesSlicedDatatypeTest",
    "org.hl7.fhir.conformance.profile.ProfileUtilitiesInheritedReslicingTest",
])
require_tests(publisher, "org.hl7.fhir.publisher.core", [
    "org.hl7.fhir.igtools.publisher.PublisherIGLoaderAdditionalResourcesTest",
])

version = ET.parse(publisher / "pom.xml").getroot().find("{*}version").text
jar = publisher / "org.hl7.fhir.publisher.cli/target" / f"org.hl7.fhir.publisher.cli-{version}.jar"
with zipfile.ZipFile(jar) as archive:
    for repo, module, entry in [
        (publisher, "org.hl7.fhir.publisher.core", "org/hl7/fhir/igtools/publisher/PublisherIGLoader.class"),
        (core, "org.hl7.fhir.services", "org/hl7/fhir/services/conformance/profile/ProfilePathProcessor.class"),
    ]:
        assert archive.read(entry) == (repo / module / "target/classes" / entry).read_bytes(), (
            f"Publisher JAR does not contain the tested class: {entry}"
        )

info = {
    "built_at": datetime.now(timezone.utc).isoformat(),
    "workflow_commit": os.environ.get("GITHUB_SHA"),
    "run_url": (f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
                if "GITHUB_RUN_ID" in os.environ else None),
    "publisher": {"upstream": revision(publisher, "upstream/master"),
                  "fix/additional-resources-from-dependencies": revision(publisher, "fixes/fix/additional-resources-from-dependencies"),
                  "combined": revision(publisher, "HEAD")},
    "core": {"upstream": revision(core, "upstream/master"),
             "fix/sliced-datatype-snapshot-recursion": revision(core, "fixes/fix/sliced-datatype-snapshot-recursion"),
             "fix/reslicing-before-inherited-siblings": revision(core, "fixes/fix/reslicing-before-inherited-siblings"),
             "combined": revision(core, "HEAD")},
    "publisher_version": version,
    "core_version": ET.parse(core / "pom.xml").getroot().find("{*}version").text,
    "sha256": hashlib.file_digest(jar.open("rb"), "sha256").hexdigest(),
}
shutil.copy2(jar, dist / "publisher.jar")
(dist / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
(dist / "release-notes.md").write_text(
    "Custom Publisher for AWMF and EBM; includes all three fixes.\n\n"
    f"Publisher upstream: HL7/fhir-ig-publisher@{info['publisher']['upstream']}\n\n"
    f"Core upstream: hapifhir/org.hl7.fhir.core@{info['core']['upstream']}\n\n"
    "The Core and Publisher regression tests passed. The packaged fix classes match "
    "the tested build. See build-info.json for exact fix commits and the JAR checksum.\n"
)
print(json.dumps(info, indent=2))
