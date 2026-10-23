# Small, dependency-free release metadata and rendering helpers.
import base64
import html
import json
import os
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def cask(version, sha):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        sys.exit("Invalid cask version or checksum")
    text = Path("packaging/pomace.rb.template").read_text()
    text = text.replace("@VERSION@", version).replace("@SHA256@", sha)
    if "@" in text or f'version "{version}"' not in text or f'sha256 "{sha}"' not in text:
        sys.exit("Invalid cask render")
    print(text, end="")


def manifest(version, commit, sha, dry_run):
    proof = dict(version=version, commit=commit, dmg_sha256=sha, dry_run=dry_run == "1")
    Path("dist/MANIFEST").write_text(json.dumps(proof, indent=2) + "\n")


def verify(version, commit, sha):
    proof = json.loads(Path("dist/MANIFEST").read_text())
    if proof.get("version") != version:
        sys.exit("MANIFEST version mismatch")
    if proof.get("commit") != commit:
        sys.exit("MANIFEST commit mismatch")
    if proof.get("dmg_sha256") != sha:
        sys.exit("MANIFEST DMG checksum mismatch")
    if proof.get("dry_run") is not False:
        sys.exit("Refusing dry-run or unclassified artifacts")


def notes(source, destination):
    # Release notes use headings, bullet lists and plain paragraphs only.
    lines = Path(source).read_text().splitlines()
    output = []
    for line in lines:
        if line.startswith("# "):
            output.append("<h1>" + html.escape(line[2:]) + "</h1>")
        elif line.startswith("- "):
            output.append("<ul><li>" + html.escape(line[2:]) + "</li></ul>")
        elif line.strip():
            output.append("<p>" + html.escape(line) + "</p>")
    Path(destination).write_text("\n".join(output) + "\n")


def key(destination, app):
    # Sparkle 2.10.0 generate_keys --help documents base64 of a 32-byte seed.
    # The staged dry-run app must carry the matching throwaway public key.
    import plistlib
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    private = Ed25519PrivateKey.generate()
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(base64.b64encode(private.private_bytes_raw()) + b"\n")
    info = Path(app) / "Contents/Info.plist"
    values = plistlib.loads(info.read_bytes())
    values["SUPublicEDKey"] = base64.b64encode(private.public_key().public_bytes_raw()).decode()
    info.write_bytes(plistlib.dumps(values))


def check_feed(version, dmg, feed, dry_run):
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    items = ET.parse(feed).findall("./channel/item")
    matches = [item for item in items if item.findtext(ns + "shortVersionString") == version]
    if len(matches) != 1 or (dry_run == "1" and len(items) != 1):
        sys.exit("Appcast must contain exactly one new release item")
    enclosure = matches[0].find("enclosure")
    expected_url = f"https://github.com/sdelavega/Pomace/releases/download/v{version}/Pomace-{version}.dmg"
    if (enclosure is None or enclosure.get("url") != expected_url
            or enclosure.get("length") != str(Path(dmg).stat().st_size)
            or not enclosure.get(ns + "edSignature")):
        sys.exit("Appcast enclosure mismatch: " + (ET.tostring(enclosure, encoding="unicode") if enclosure is not None else "missing enclosure"))
    if matches[0].findtext(ns + "minimumSystemVersion") != "14.0":
        sys.exit("Appcast deployment floor mismatch")
    if not matches[0].findtext("description", "").strip():
        sys.exit("Appcast release notes missing")
    print(enclosure.get(ns + "edSignature"))


if __name__ == "__main__":
    commands = {"cask": cask, "manifest": manifest, "verify": verify,
                "notes": notes, "key": key, "check-feed": check_feed}
    commands[sys.argv[1]](*sys.argv[2:])
