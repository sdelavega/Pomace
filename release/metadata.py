# Small, dependency-free release metadata and rendering helpers.
import base64
import html
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


def build_number(version, override=""):
    number = 1
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        major, minor, patch = map(int, version.split("."))
        if any(component > 99 for component in (major, minor, patch)):
            sys.exit("Version components must be 0–99")
        number = major * 10000 + minor * 100 + patch
    if override:
        if not re.fullmatch(r"[0-9]+", override):
            sys.exit("POMACE_BUILD must be a non-negative integer")
        number = int(override)
    print(number)


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
    in_list = False
    for line in lines:
        if in_list and not line.startswith("- "):
            output.append("</ul>")
            in_list = False
        if line.startswith("# "):
            output.append("<h1>" + html.escape(line[2:]) + "</h1>")
        elif line.startswith("- "):
            if not in_list:
                output.append("<ul>")
                in_list = True
            output.append("<li>" + html.escape(line[2:]) + "</li>")
        elif line.strip():
            output.append("<p>" + html.escape(line) + "</p>")
    if in_list:
        output.append("</ul>")
    Path(destination).write_text("\n".join(output) + "\n")


def key(destination, app):
    # Sparkle 2.10.0 generate_keys --help documents base64 of a 32-byte seed.
    # Validate the RFC 8410 PKCS#8/SPKI wrappers before extracting raw keys.
    private = subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-outform", "DER"],
                             capture_output=True, check=True).stdout
    public = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                            input=private, capture_output=True, check=True).stdout
    private_prefix = bytes.fromhex("302e020100300506032b657004220420")
    public_prefix = bytes.fromhex("302a300506032b6570032100")
    if (len(private) != len(private_prefix) + 32 or not private.startswith(private_prefix)
            or len(public) != len(public_prefix) + 32 or not public.startswith(public_prefix)):
        sys.exit("Unexpected OpenSSL Ed25519 key format")
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(base64.b64encode(private[len(private_prefix):]) + b"\n")
    info = Path(app) / "Contents/Info.plist"
    values = plistlib.loads(info.read_bytes())
    values["SUPublicEDKey"] = base64.b64encode(public[len(public_prefix):]).decode()
    info.write_bytes(plistlib.dumps(values))


def check_feed(version, dmg, feed, dry_run, app, sign_update):
    ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    values = plistlib.loads((Path(app) / "Contents/Info.plist").read_bytes())
    items = ET.parse(feed).findall("./channel/item")
    matches = [item for item in items if item.findtext(ns + "shortVersionString") == version]
    if len(matches) != 1 or (dry_run == "1" and len(items) != 1):
        sys.exit("Appcast must contain exactly one new release item")
    if values["CFBundleShortVersionString"] != version:
        sys.exit("Bundle marketing version mismatch")
    if matches[0].findtext(ns + "version") != str(values["CFBundleVersion"]):
        sys.exit("Appcast build version mismatch")
    enclosure = matches[0].find("enclosure")
    expected_url = f"https://github.com/sdelavega/Pomace/releases/download/v{version}/Pomace-{version}.dmg"
    if (enclosure is None or enclosure.get("url") != expected_url
            or enclosure.get("length") != str(Path(dmg).stat().st_size)
            or not enclosure.get(ns + "edSignature")):
        sys.exit("Appcast enclosure mismatch")
    if matches[0].findtext(ns + "minimumSystemVersion") != "14.0":
        sys.exit("Appcast deployment floor mismatch")
    if not matches[0].findtext("description", "").strip():
        sys.exit("Appcast release notes missing")
    public = base64.b64decode(values["SUPublicEDKey"], validate=True)
    if len(public) != 32:
        sys.exit("Invalid Sparkle public key")
    # Sparkle's legacy 96-byte verification input uses only the public suffix.
    # The 64 zero bytes are inert padding, never a private signing key.
    verification_key = base64.b64encode(bytes(64) + public)
    for path, signature in ((dmg, [enclosure.get(ns + "edSignature")]), (feed, [])):
        result = subprocess.run([sign_update, "--verify", path, *signature, "--ed-key-file", "-"],
                                input=verification_key, capture_output=True)
        if result.returncode != 0:
            sys.exit("Appcast signature verification failed")
    print("Appcast build and signatures verified")


if __name__ == "__main__":
    commands = {"build-number": build_number, "cask": cask, "manifest": manifest, "verify": verify,
                "notes": notes, "key": key, "check-feed": check_feed}
    commands[sys.argv[1]](*sys.argv[2:])
