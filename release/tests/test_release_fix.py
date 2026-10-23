# Release regressions use fake builds and disposable signing keys only.
import base64
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class BuildVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy(ROOT / "build-app.sh", self.root)
        shutil.copytree(ROOT / "release", self.root / "release")
        resources = self.root / "Resources"
        resources.mkdir()
        (resources / "Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleShortVersionString="1.0.2", CFBundleVersion="1")))
        for name in ("Pomace.icns", "com.sdelavega.Pomace.Sweep.plist"):
            (resources / name).write_text("fixture")
        self.products = self.root / "products"
        self.products.mkdir()
        (self.products / "PomaceApp").write_text("fake executable")
        (self.products / "Pomace_PomaceApp.bundle").mkdir()
        framework = self.root / ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-fixture/Sparkle.framework"
        framework.mkdir(parents=True)
        (framework / "sentinel").write_text("fake framework")
        (self.root / "build").mkdir()
        (self.root / "build/applesauce").write_text("fake helper")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        scripts = {
            "swift": '#!/bin/bash\nfor arg in "$@"; do\n'
                     + f'  if [ "$arg" = --show-bin-path ]; then echo {shlex.quote(str(self.products))}; fi\n'
                     + 'done\n',
            "codesign": '#!/bin/bash\nprintf "%s\\n" "$*" >> '
                        + shlex.quote(str(self.root / "signatures")) + '\n',
            "security": '#!/bin/bash\necho invoked > '
                        + shlex.quote(str(self.root / "security-called")) + '\nexit 91\n',
        }
        for name, script in scripts.items():
            path = self.bin / name
            path.write_text(script)
            path.chmod(0o755)

    def build(self, version, override=None):
        values = {key: value for key, value in os.environ.items()
                  if key not in {"POMACE_VERSION", "POMACE_BUILD", "POMACE_SIGN_ADHOC", "POMACE_SIGN_ID"}}
        values.update(PATH=str(self.bin) + ":" + os.environ["PATH"],
                      POMACE_VERSION=version, POMACE_SIGN_ADHOC="1", POMACE_SIGN_ID="fixture")
        if override is not None:
            values["POMACE_BUILD"] = override
        return subprocess.run(["bash", "build-app.sh", "release"], cwd=self.root,
                              env=values, text=True, capture_output=True)

    def test_bundle_build_numbers(self):
        for version, override, expected in (("1.1.0", None, "10100"),
                                            ("1.0.2", None, "10002"),
                                            ("2.0.0", None, "20000"),
                                            ("0.0.0-dryrun", None, "1"),
                                            ("1.1.0", "10101", "10101"),
                                            ("0.0.0-dryrun", "7", "7")):
            with self.subTest(version=version, override=override):
                result = self.build(version, override)
                self.assertEqual(result.returncode, 0, result.stderr)
                info = self.root / "build/Pomace.app/Contents/Info.plist"
                self.assertTrue(info.is_file())
                values = plistlib.loads(info.read_bytes())
                self.assertEqual(values["CFBundleShortVersionString"], version)
                self.assertEqual(values["CFBundleVersion"], expected)
        for version in ("1.100.0", "100.0.0", "1.0.100"):
            with self.subTest(invalid=version):
                result = self.build(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("0–99", result.stderr)

    def test_requested_adhoc_signing(self):
        result = self.build("1.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ad-hoc signed (requested)", result.stdout)
        self.assertFalse((self.root / "security-called").exists())
        signatures = (self.root / "signatures").read_text().splitlines()
        signing = [line for line in signatures if "--force" in line]
        self.assertEqual(len(signing), 7)
        self.assertTrue(all("--sign -" in line and "--timestamp" not in line for line in signing))


class MetadataFixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Pomace.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleShortVersionString="1.1.0", CFBundleVersion="10100",
            SUPublicEDKey=base64.b64encode(bytes(32)).decode())))
        self.key = self.root / "ed-key"
        self.tools = ROOT / "build/sparkle-tools/bin"

    def metadata(self, *args, no_site=True, values=None):
        return subprocess.run([sys.executable, *(["-S"] if no_site else []),
                               str(ROOT / "release/metadata.py"), *map(str, args)],
                              cwd=ROOT, env=values, text=True, capture_output=True)

    def prepare_feed(self):
        # -S excludes site packages from all metadata helper invocations.
        result = self.metadata("key", self.key, self.app)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.signed_feed()

    def signed_feed(self, build="10100", marketing="1.1.0"):
        prepared = subprocess.run(["bash", str(ROOT / "release/release-tools.sh")],
                                  text=True, capture_output=True)
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        self.dmg = self.root / "Pomace-1.1.0.dmg"
        self.dmg.write_bytes(b"disposable signed archive")
        signed = subprocess.run([str(self.tools / "sign_update"), "-p", str(self.dmg),
                                 "--ed-key-file", str(self.key)], text=True, capture_output=True)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        feed = ET.Element("rss", version="2.0")
        item = ET.SubElement(ET.SubElement(feed, "channel"), "item")
        for tag, text in ((NS + "version", build), (NS + "shortVersionString", marketing),
                          (NS + "minimumSystemVersion", "14.0"), ("description", "Fixture notes")):
            ET.SubElement(item, tag).text = text
        ET.SubElement(item, "enclosure", {
            "url": "https://github.com/sdelavega/Pomace/releases/download/v1.1.0/Pomace-1.1.0.dmg",
            "length": str(self.dmg.stat().st_size), NS + "edSignature": signed.stdout.strip()})
        self.feed = self.root / "appcast.xml"
        ET.ElementTree(feed).write(self.feed, encoding="utf-8", xml_declaration=True)
        signed = subprocess.run([str(self.tools / "sign_update"), str(self.feed),
                                 "--ed-key-file", str(self.key)], text=True, capture_output=True)
        self.assertEqual(signed.returncode, 0, signed.stderr)

    def check_feed(self):
        return self.metadata("check-feed", "1.1.0", self.dmg, self.feed, "1",
                             self.app, self.tools / "sign_update")

    def test_openssl_key_signatures(self):
        real_openssl = shutil.which("openssl")
        self.assertIsNotNone(real_openssl)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        log = self.root / "openssl-called"
        wrapper = bin_dir / "openssl"
        wrapper.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> '
                           + shlex.quote(str(log)) + '\nexec '
                           + shlex.quote(real_openssl) + ' "$@"\n')
        wrapper.chmod(0o755)
        result = self.metadata("key", self.key, self.app,
                               values={**os.environ, "PATH": str(bin_dir) + ":" + os.environ["PATH"]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("genpkey -algorithm ed25519", log.read_text())
        self.assertEqual(self.key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(len(base64.b64decode(self.key.read_bytes(), validate=False)), 32)
        self.signed_feed()
        result = self.check_feed()
        self.assertEqual(result.returncode, 0, result.stderr)
        values = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.assertNotEqual(values["SUPublicEDKey"], base64.b64encode(bytes(32)).decode())
        values["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(values))
        result = self.check_feed()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature", result.stderr.lower())

    def test_feed_versions(self):
        self.prepare_feed()
        good = self.check_feed()
        self.assertEqual(good.returncode, 0, good.stderr)
        for build, marketing, diagnostic in (("1", "1.1.0", "build"),
                                              ("10100", "1.0.2", "release item")):
            with self.subTest(build=build, marketing=marketing):
                self.signed_feed(build, marketing)
                result = self.check_feed()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)

    def test_notes_group_bullets(self):
        source = self.root / "notes.md"
        destination = self.root / "notes.html"
        source.write_text("# Notes\n- One & two\n- Three\n\nParagraph\n- Four\n- Five\n# End\n")
        result = self.metadata("notes", source, destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        document = ET.fromstring("<div>" + destination.read_text() + "</div>")
        self.assertEqual([element.tag for element in document], ["h1", "ul", "p", "ul", "h1"])
        self.assertEqual([[item.text for item in group] for group in document.findall("ul")],
                         [["One & two", "Three"], ["Four", "Five"]])


if __name__ == "__main__":
    unittest.main()
