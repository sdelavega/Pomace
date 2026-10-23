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

    def run_check(self, mode, locales=('en',)):
        self.assertTrue(SCRIPT.is_file(), 'localization checker must exist')
        args = ['python3', str(SCRIPT), mode, '--root', str(self.root)]
        if mode == 'catalog':
            args += ['--locales', *locales]
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

    @staticmethod
    def unit(value, state='translated'):
        return {'stringUnit': {'state': state, 'value': value}}

    def localized(self, translations):
        self.write_catalog({'sample.key': {'localizations': translations}})

    def plural(self, **values):
        return {'variations': {'plural': {category: self.unit(value) for category, value in values.items()}}}

    def test_specifier_mismatch_fails(self):
        for source, target in [('%lld files', '%@ Dateien'), ('%1$@ %2$d', '%1$@ %2$lld'),
                               ('%@ %@', '%@'), ('%ld files', '%d Dateien')]:
            with self.subTest(source=source, target=target):
                self.localized({'en': self.unit(source), 'de': self.unit(target)})
                result = self.run_check('catalog', ('en', 'de'))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('specifier', result.stderr)
        self.localized({'en': self.unit('%1$@ %2$d %%'), 'de': self.unit('%2$d %1$@ %%')})
        self.assertEqual(self.run_check('catalog', ('en', 'de')).returncode, 0)

    def test_missing_plural_category_fails(self):
        self.localized({'en': self.plural(one='%lld file', other='%lld files'),
                        'fr': self.plural(other='%lld fichiers', many='%lld fichiers')})
        result = self.run_check('catalog', ('en', 'fr'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('one', result.stderr)
        self.localized({'en': self.plural(one='%lld file', other='%lld files'),
                        'fr': self.plural(one='%lld fichier', other='%lld fichiers')})
        self.assertIn('many', self.run_check('catalog', ('en', 'fr')).stderr)

    def test_cjk_other_only_passes(self):
        translations = {'en': self.plural(one='%lld file', other='%lld files')}
        for locale in ['zh-Hans', 'ja', 'ko']:
            translations[locale] = self.plural(other='%lld 件')
        self.localized(translations)
        result = self.run_check('catalog', tuple(translations))
        self.assertEqual(result.returncode, 0, result.stderr)
        translations['ja'] = self.plural(other='%@ 件')
        self.localized(translations)
        result = self.run_check('catalog', tuple(translations))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('specifier', result.stderr)

    def test_untranslated_state_fails(self):
        for state in ['new', 'stale', 'needs_review', None]:
            with self.subTest(state=state):
                self.localized({'en': self.unit('Hello'), 'de': self.unit('Hallo', state)})
                result = self.run_check('catalog', ('en', 'de'))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('translated', result.stderr)
        self.localized({'en': self.unit('Hello'), 'de': self.unit('Hallo')})
        self.assertEqual(self.run_check('catalog', ('en', 'de')).returncode, 0)

    def test_locales_enforces_each_requested_locale(self):
        self.localized({'en': self.unit('Hello'), 'de': self.unit('Hallo')})
        self.assertEqual(self.run_check('catalog', ('en', 'de')).returncode, 0)
        result = self.run_check('catalog', ('en', 'de', 'ko'))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ko', result.stderr)
        self.localized({'en': self.unit('Hello'), 'ko': self.unit('')})
        self.assertIn('missing ko value', self.run_check('catalog', ('ko',)).stderr)
        self.assertIn('unsupported locale', self.run_check('catalog', ('xx',)).stderr)

    def test_plural_units_are_checked(self):
        source = self.plural(one='%lld file', other='%lld files')
        for bad in [self.unit(''), self.unit('%@ Dateien'), self.unit('%lld Dateien', 'new')]:
            with self.subTest(bad=bad):
                self.localized({'en': source, 'de': {'variations': {'plural': {
                    'one': self.unit('%lld Datei'), 'other': bad}}}})
                self.assertNotEqual(self.run_check('catalog', ('en', 'de')).returncode, 0)
        self.localized({'en': source, 'de': self.plural(one='%lld Datei', other='%lld Dateien')})
        self.assertEqual(self.run_check('catalog', ('en', 'de')).returncode, 0)

    def test_lint_flags_multiline_text(self):
        self.swift('Text("""\nHello\n""")')
        result = self.run_check('lint')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Fixture.swift:1', result.stderr)
        self.swift('Text("—")\nText("""\n—\n""")')
        self.assertEqual(self.run_check('lint').returncode, 0)

    def test_lint_flags_additional_controls(self):
        for expression in ['Picker("Mode", selection: $mode) {}',
                           'TableColumn("Name") { Text($0.name) }',
                           'ContentUnavailableView("Empty", systemImage: "folder")']:
            with self.subTest(expression=expression):
                self.swift(expression)
                result = self.run_check('lint')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Fixture.swift:1', result.stderr)

    def test_lint_flags_panel_assignments(self):
        for panel_type in ['NSOpenPanel', 'NSSavePanel']:
            for property_name in ['prompt', 'message']:
                with self.subTest(panel_type=panel_type, property_name=property_name):
                    self.swift(f'let chooser = {panel_type}()\nchooser.{property_name} = "Choose a file"')
                    result = self.run_check('lint')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('Fixture.swift:2', result.stderr)
        self.swift('let chooser = NSOpenPanel()\nchooser.prompt = AppStrings.scan\n'
                   'chooser.message = "Pomace" // l10n-exempt: Product name\n'
                   '// chooser.prompt = "Comment"\nlet example = "Text(\\"Hello\\")"')
        self.assertEqual(self.run_check('lint').returncode, 0)


if __name__ == '__main__':
    unittest.main()
