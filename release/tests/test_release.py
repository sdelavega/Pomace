# Release checks use disposable repositories and never publish.
import hashlib
import json
import os
from pathlib import Path
import shutil
import plistlib
import xml.etree.ElementTree as ET
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("release", "packaging"):
            if (ROOT / directory).is_dir():
                shutil.copytree(ROOT / directory, self.root / directory)
            else:
                (self.root / directory).mkdir()
        self.git("init", "-q")
        self.git("-c", "user.name=alex", "-c", "user.email=alex@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fixture")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()
        self.dist = self.root / "dist"
        self.dist.mkdir()
        self.dmg = self.dist / "Pomace-1.1.0.dmg"
        self.dmg.write_bytes(b"disposable DMG fixture")
        self.sha = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        self.prepare_signed_feed()
        self.tap = self.root / "tap"
        self.tap.mkdir()
        (self.tap / "sentinel").write_text("unchanged")
        self.proof = dict(version="1.1.0", commit=self.head, dmg_sha256=self.sha, dry_run=False,
                          appcast_sha256=hashlib.sha256((self.dist / "appcast.xml").read_bytes()).hexdigest())
        self.write_manifest()

    def prepare_signed_feed(self):
        prepared = subprocess.run(["bash", str(ROOT / "release/release-tools.sh")], capture_output=True, text=True)
        self.assertEqual(prepared.returncode, 0, prepared.stderr)
        tools = self.root / "build/sparkle-tools"
        tools.mkdir(parents=True)
        (tools / "bin").symlink_to(ROOT / "build/sparkle-tools/bin", target_is_directory=True)
        self.signer = tools / "bin/sign_update"
        self.app = self.root / "build/Pomace.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleShortVersionString="1.1.0", CFBundleVersion="10100")))
        key = self.root / "disposable-key"
        result = subprocess.run(["python3", str(self.root / "release/metadata.py"), "key", str(key), str(self.app)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        signed = subprocess.run([str(self.signer), "-p", str(self.dmg), "--ed-key-file", str(key)], capture_output=True, text=True)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
        rss = ET.Element("rss", version="2.0")
        item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
        for tag, value in ((ns + "version", "10100"), (ns + "shortVersionString", "1.1.0"),
                           (ns + "minimumSystemVersion", "14.0"), ("description", "Disposable fixture")):
            ET.SubElement(item, tag).text = value
        ET.SubElement(item, "enclosure", {"url": "https://github.com/sdelavega/Pomace/releases/download/v1.1.0/Pomace-1.1.0.dmg",
            "length": str(self.dmg.stat().st_size), ns + "edSignature": signed.stdout.strip()})
        feed = self.dist / "appcast.xml"
        ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
        signed = subprocess.run([str(self.signer), str(feed), "--ed-key-file", str(key)], capture_output=True, text=True)
        self.assertEqual(signed.returncode, 0, signed.stderr)
        key.unlink()

    def test_invalid_appcast_refused_before_mutation(self):
        feed = self.dist / "appcast.xml"
        original = feed.read_bytes()
        for kind in ("changed", "missing-release", "signature", "enclosure"):
            with self.subTest(kind=kind):
                feed.write_bytes(original)
                if kind == "changed":
                    feed.write_bytes(original + b"\n")
                elif kind == "missing-release":
                    feed.write_text("<rss><channel/></rss>")
                elif kind == "signature":
                    feed.write_bytes(original.replace(b"Disposable fixture", b"Untrusted fixture"))
                else:
                    feed.write_bytes(original.replace(b"/v1.1.0/", b"/v1.0.2/"))
                self.proof["appcast_sha256"] = hashlib.sha256(original if kind == "changed" else feed.read_bytes()).hexdigest()
                self.write_manifest()
                self.assertNotEqual(feed.read_bytes(), original)
                result = self.publish()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("git tag", result.stdout)
                self.assertNotIn("gh release", result.stdout)
                diagnostic = {"changed": "checksum", "missing-release": "release item", "signature": "signature", "enclosure": "enclosure"}[kind]
                self.assertIn(diagnostic, result.stderr)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args],
                              text=True, capture_output=True, check=True)

    def write_manifest(self):
        (self.dist / "MANIFEST").write_text(json.dumps(self.proof))

    def publish(self):
        # Shadow every publishing executable; fake mode must never invoke them.
        bin_dir = self.root / "bin"
        bin_dir.mkdir(exist_ok=True)
        marker = self.root / "executed"
        real_git = shutil.which("git")
        for name in ("git", "gh", "cp", "mkdir", "mv", "rm"):
            path = bin_dir / name
            path.write_text("#!/bin/bash\n"
                            + (f'if [[ "$1" == rev-parse ]]; then exec "{real_git}" "$@"; fi\n'
                               if name == "git" else "")
                            + f'echo invoked >> "{marker}"\nexit 91\n')
            path.chmod(0o755)
        result = subprocess.run(["bash", "release/publish.sh", "1.1.0"], cwd=self.root,
                                env={**os.environ, "PATH": str(bin_dir) + ":" + os.environ["PATH"],
                                     "POMACE_PUBLISH_FAKE": "1", "POMACE_TAP_DIR": str(self.tap)},
                                capture_output=True, text=True)
        self.assertFalse(marker.exists(), result.stdout + result.stderr)
        self.assertEqual(list(self.tap.iterdir()), [self.tap / "sentinel"])
        self.assertEqual((self.tap / "sentinel").read_text(), "unchanged")
        self.assertEqual(self.git("tag", "--list").stdout, "")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.head)
        return result

    def test_cask_renders(self):
        template = self.root / "packaging/pomace.rb.template"
        self.assertTrue(template.is_file())
        result = subprocess.run(["python3", "release/metadata.py", "cask", "1.1.0", self.sha],
                                cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('version "1.1.0"', result.stdout)
        self.assertIn(f'sha256 "{self.sha}"', result.stdout)
        self.assertNotIn("@", result.stdout)
        self.assertIn('uninstall launchctl: "com.sdelavega.Pomace.Sweep"', result.stdout)

    def test_manifest_mismatch_refused(self):
        self.assertEqual(self.proof["dmg_sha256"], self.sha)
        for field, value, diagnostic in (("dmg_sha256", "0" * 64, "checksum"),
                                         ("commit", "0" * 40, "commit"),
                                         ("version", "1.0.0", "version"),
                                         ("dry_run", True, "dry-run")):
            with self.subTest(field=field):
                original = self.proof[field]
                self.proof[field] = value
                self.write_manifest()
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(diagnostic, result.stderr)
                self.assertNotIn("gh release", result.stdout)
                self.proof[field] = original

    def test_publish_fake_prints_plan(self):
        self.assertEqual(json.loads((self.dist / "MANIFEST").read_text()), self.proof)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = ["git tag -a v1.1.0", "gh release create v1.1.0",
                    "git worktree add", "HEAD:refs/heads/gh-pages", "Casks/pomace.rb", "push origin HEAD \n"]
        positions = [result.stdout.index(command) for command in commands]
        self.assertEqual(positions, sorted(positions), result.stdout)

    def test_tool_hash_mismatch_refused(self):
        pins = ROOT / "release/sparkle-tools.sha256"
        self.assertTrue(pins.is_file())
        tools = self.root / "tools"
        tools.mkdir()
        entries = [line.split() for line in pins.read_text().splitlines() if line.strip()]
        self.assertEqual({entry[1] for entry in entries}, {"generate_appcast", "sign_update", "generate_keys"})
        for _, name in entries:
            (tools / name).write_bytes(b"tampered executable")
        result = subprocess.run(["bash", "release/release-tools.sh", "--check", str(tools)],
                                cwd=self.root, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
