#!/usr/bin/env python3
# Checks localization lint and catalog coverage with disposable app fixtures.
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/check-l10n.py'


class LocalizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'Sources/PomaceApp'
        self.app.mkdir(parents=True)
        self.catalog = self.app / 'Resources/Localizable.xcstrings'
        self.catalog.parent.mkdir()
        self.write_catalog({'sample.key': self.english('Hello')})

    @staticmethod
    def english(value):
        return {'localizations': {'en': {'stringUnit': {'state': 'translated', 'value': value}}}}

    def write_catalog(self, strings):
        self.catalog.write_text(json.dumps({'sourceLanguage': 'en', 'version': '1.0', 'strings': strings}))

    def swift(self, content):
        path = self.app / 'Fixture.swift'
        path.write_text(content)
        self.assertEqual(path.read_text(), content)

    def run_check(self, mode):
        self.assertTrue(SCRIPT.is_file(), 'localization checker must exist')
        args = ['python3', str(SCRIPT), mode, '--root', str(self.root)]
        if mode == 'catalog':
            args += ['--locales', 'en']
        return subprocess.run(args, capture_output=True, text=True)

    def test_lint_flags_bare_text(self):
        for expression in ['Text("Hello")', 'Button("Go") {}', 'Label("Name", systemImage: "star")',
                           '.help("Help")', 'Toggle("Enabled", isOn: $enabled)',
                           '.navigationTitle("Title")', 'Section("Heading") {}',
                           '.accessibilityLabel("Name")']:
            with self.subTest(expression=expression):
                self.swift(expression)
                result = self.run_check('lint')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('Fixture.swift:1', result.stderr)

    def test_lint_allows_exempt(self):
        self.swift('Text("Pomace") // l10n-exempt: Product name\n')
        result = self.run_check('lint')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.swift('Text("Pomace") // l10n-exempt:\n')
        self.assertNotEqual(self.run_check('lint').returncode, 0)

    def test_lint_allows_bundle_module(self):
        self.swift('Text("k", bundle: .module)\nText(\n "sample.key",\n bundle: .module\n)')
        result = self.run_check('lint')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_catalog_missing_en_fails(self):
        self.swift('// No localized calls in this fixture.\n')
        self.write_catalog({'sample.key': {'localizations': {}}})
        result = self.run_check('catalog')
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('sample.key', result.stderr)
        self.assertIn('en', result.stderr)
        self.write_catalog({'sample.key': self.english('Hello')})
        self.assertEqual(self.run_check('catalog').returncode, 0)

    def test_catalog_missing_code_key_fails(self):
        expressions = ['AppStrings.text("missing.key", defaultValue: "Hello", comment: "Greeting")',
                       'NSLocalizedString("core.missing", tableName: "Localizable", bundle: .module, value: "Hello", comment: "Greeting")',
                       'Text("missing.key", bundle: .module)',
                       'String(localized: "missing.key", bundle: .module)',
                       'LocalizedStringKey("missing.key")',
                       'String(localized: "missing.key", defaultValue: "\\(count) files", bundle: .module)']
        for expression in expressions:
            with self.subTest(expression=expression):
                self.swift(expression)
                result = self.run_check('catalog')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('missing', result.stderr)
                self.write_catalog({'sample.key': self.english('Hello'),
                                    'missing.key': self.english('Hello'), 'core.missing': self.english('Hello')})
                self.assertEqual(self.run_check('catalog').returncode, 0)
                self.write_catalog({'sample.key': self.english('Hello')})


if __name__ == '__main__':
    unittest.main()
