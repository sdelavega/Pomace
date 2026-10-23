#!/usr/bin/env python3
# Checks the AX fixture's GUI-session decision without launching an app.
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/check-ax.swift'


class AXSessionTests(unittest.TestCase):
    def test_gui_session_decision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness = root / 'main.swift'
            harness.write_text(SCRIPT.read_text() + '\n' + '''import CoreGraphics
let console = kCGSessionOnConsoleKey as String
let login = kCGSessionLoginDoneKey as String
let locked = "CGSSessionScreenIsLocked"
let cases: [(String, [String: Any]?)] = [
    ("no session", nil),
    ("empty session", [:]),
    ("off console", [console: false, login: true, locked: false]),
    ("login incomplete", [console: true, login: false, locked: false]),
    ("login missing", [console: true, locked: false]),
    ("locked console", [console: true, login: true, locked: true]),
    ("unlocked console", [console: true, login: true, locked: false]),
    ("lock key absent", [console: true, login: true]),
]
for (name, session) in cases {
    print("\\(name)=\\(hasUnlockedGUISession(session))")
}
''')
            binary = root / 'check-session'
            compiled = subprocess.run(
                ['swiftc', '-D', 'CHECK_AX_SESSION_TEST', str(harness), '-o', str(binary)],
                capture_output=True, text=True, cwd=ROOT,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            decisions = dict(line.rsplit('=', 1) for line in result.stdout.splitlines())
            expected = {
                'no session': 'false',
                'empty session': 'false',
                'off console': 'false',
                'login incomplete': 'false',
                'login missing': 'false',
                'locked console': 'false',
                'unlocked console': 'true',
                'lock key absent': 'true',
            }
            self.assertEqual(len(result.stdout.splitlines()), len(expected))
            self.assertEqual(decisions.keys(), expected.keys())
            for name, allowed in expected.items():
                with self.subTest(session=name):
                    self.assertEqual(decisions[name], allowed)


if __name__ == '__main__':
    unittest.main()
