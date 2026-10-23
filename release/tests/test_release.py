# Release checks use disposable repositories and never publish.
import hashlib
import json
import os
from pathlib import Path
import shutil
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
        (self.dist / "appcast.xml").write_text("<rss><channel/></rss>")
        self.tap = self.root / "tap"
        self.tap.mkdir()
        (self.tap / "sentinel").write_text("unchanged")
        self.proof = dict(version="1.1.0", commit=self.head, dmg_sha256=self.sha, dry_run=False)
        self.write_manifest()

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
