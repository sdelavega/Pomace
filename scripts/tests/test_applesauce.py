#!/usr/bin/env python3
# Checks the helper gate and compressor selection with disposable command fixtures.
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HelperScriptsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / '.cargo/bin'
        self.bin.mkdir(parents=True)
        self.log = self.root / 'commands'
        self.environment = dict(os.environ, HOME=str(self.root),
                                PATH=f'{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin',
                                COMMAND_LOG=str(self.log))
        self.environment.pop('POMACE_COMPRESSOR', None)
        self.script('hdiutil', 'echo "disk $*" >> "$COMMAND_LOG"')
        self.script('swift', 'echo "swift $*" >> "$COMMAND_LOG"\necho "applesauce: ${REPORTED_COMPRESSOR:-$POMACE_COMPRESSOR} (a location you chose)"')
        self.write('spikes/make-corpus.sh', '#!/bin/bash\nmkdir -p "$1"\n')
        source = ROOT / 'Tests/integration/sparse-image.sh'
        self.assertTrue(source.is_file())
        destination = self.root / 'Tests/integration/sparse-image.sh'
        destination.parent.mkdir(parents=True)
        shutil.copy2(source, destination)

    def write(self, path, content):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
        destination.chmod(0o755)
        return destination

    def script(self, name, content):
        return self.write(f'.cargo/bin/{name}', '#!/bin/bash\nset -eu\n' + content + '\n')

    def integration(self):
        return subprocess.run(['bash', str(self.root / 'Tests/integration/sparse-image.sh')],
                              cwd=self.root, env=self.environment, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_missing_helper_fails_before_disk_creation(self):
        missing = self.root / 'missing helper'
        self.assertFalse(missing.exists())
        self.environment['POMACE_COMPRESSOR'] = str(missing)
        result = self.integration()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(str(missing), result.stdout)
        self.assertIn('not executable', result.stdout)
        self.assertFalse(self.log.exists(), result.stdout)

    def test_default_helper_is_exported_as_absolute_path(self):
        helper = self.write('build/applesauce', '#!/bin/bash\nexit 0\n')
        self.assertTrue(os.access(helper, os.X_OK))
        result = self.integration()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(f'applesauce: {helper} (', result.stdout)
        self.assertIn('swift run pomace-spike engine-verify', self.log.read_text())

    def test_custom_helper_and_wrong_reported_path(self):
        helper = self.write('custom helper/applesauce', '#!/bin/bash\nexit 0\n')
        self.environment['POMACE_COMPRESSOR'] = 'custom helper/applesauce'
        result = self.integration()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(f'applesauce: {helper} (', result.stdout)
        self.environment['REPORTED_COMPRESSOR'] = '/wrong/applesauce'
        result = self.integration()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('did not use', result.stdout)
        self.assertIn(str(helper), result.stdout)

    def test_gate_order_and_stops_on_failure(self):
        source = ROOT / 'scripts/gate.sh'
        self.assertTrue(source.is_file(), 'scripts/gate.sh must exist')
        destination = self.root / 'scripts/gate.sh'
        destination.parent.mkdir(parents=True)
        shutil.copy2(source, destination)
        self.script('swift', 'echo swift >> "$COMMAND_LOG"')
        self.script('cargo', 'echo "cargo $*" >> "$COMMAND_LOG"\nif [ "${FAIL_CARGO_TEST:-0}" = 1 ] && [ "$1" = test ]; then exit 17; fi')
        self.write('scripts/build-applesauce.sh', '#!/bin/bash\necho build >> "$COMMAND_LOG"\n')
        self.write('Tests/integration/sparse-image.sh', '#!/bin/bash\necho integration >> "$COMMAND_LOG"\n')
        self.write('build-app.sh', '#!/bin/bash\necho "app $*" >> "$COMMAND_LOG"\n')
        self.write('scripts/check-bundle.sh', '#!/bin/bash\necho "bundle $*" >> "$COMMAND_LOG"\n')
        expected = ['swift', 'build', 'cargo test --manifest-path tools/applesauce/Cargo.toml --locked',
                    'cargo deny --manifest-path tools/applesauce/Cargo.toml --config tools/applesauce/deny.toml check licenses',
                    'integration', 'app release', 'bundle --universal build/Pomace.app']
        result = subprocess.run(['bash', str(destination)], cwd=self.root,
                                env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), expected)
        self.log.unlink()
        self.environment['FAIL_CARGO_TEST'] = '1'
        result = subprocess.run(['bash', str(destination)], cwd=self.root,
                                env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), expected[:3])


if __name__ == '__main__':
    unittest.main()
