#!/usr/bin/env python3
# Exercise release rpath cleanup and validation with disposable universal Mach-O files.
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ALLOWED = ['/usr/lib/swift', '@loader_path', '@executable_path/../Frameworks']
TOOLCHAIN = ['/Applications/Xcode.app/Contents/Developer/Toolchains/Test Toolchain/usr/lib/swift',
             '/var/run/com.apple.security.cryptexd/mnt/Test/usr/lib/swift',
             '/Library/Developer/CommandLineTools/usr/lib/swift']


def run(*args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, check=True, **kwargs)


def rpaths(binary):
    lines = run('otool', '-l', str(binary)).stdout.splitlines()
    return [lines[i + 2].strip().removeprefix('path ').rsplit(' (offset ', 1)[0]
            for i, line in enumerate(lines) if line.strip() == 'cmd LC_RPATH']


class BundleRpathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.fixture = Path(cls.temp.name) / 'fixture'
        source = Path(cls.temp.name) / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        run('xcrun', 'clang', '-arch', 'arm64', '-arch', 'x86_64', str(source),
            '-o', str(cls.fixture), '-Wl,-headerpad_max_install_names',
            *[f'-Wl,-rpath,{path}' for path in ALLOWED + TOOLCHAIN])
        cls.assert_archs = set(run('lipo', '-archs', str(cls.fixture)).stdout.split())
        if cls.assert_archs != {'arm64', 'x86_64'}:
            raise AssertionError('fixture must contain both architectures')
        if set(rpaths(cls.fixture)) != set(ALLOWED + TOOLCHAIN):
            raise AssertionError('fixture must contain every allowed and toolchain rpath')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.environment = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin',
                                POMACE_SIGN_ADHOC='1', POMACE_VERSION='1.1.0')
        self.environment.pop('POMACE_BUILD', None)
        self.app = self.root / 'build/Pomace.app'
        self.products = self.root / 'products'
        self.products.mkdir()
        shutil.copy2(self.fixture, self.products / 'PomaceApp')
        for locale in ['en', 'zh-Hans', 'es', 'ja', 'ko', 'de', 'fr', 'pt-BR']:
            directory = self.products / 'Pomace_PomaceApp.bundle' / f'{locale}.lproj'
            directory.mkdir(parents=True)
            (directory / 'Localizable.stringsdict').write_text('fixture plural rules')
        framework = self.root / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-test/Sparkle.framework'
        framework.mkdir(parents=True)
        for relative in ['Sparkle', 'Versions/B/Autoupdate',
                         'Versions/B/Updater.app/Contents/MacOS/Updater',
                         'Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer',
                         'Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader']:
            destination = framework / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.fixture, destination)
            for path in TOOLCHAIN:
                run('install_name_tool', '-delete_rpath', path, str(destination))
        (self.root / 'build').mkdir()
        shutil.copy2(framework / 'Sparkle', self.root / 'build/applesauce')
        for relative in ['build-app.sh', 'scripts/check-bundle.sh', 'scripts/lib/rpaths.sh',
                         'release/metadata.py',
                         'Resources/Info.plist', 'Resources/Pomace.icns',
                         'Resources/com.sdelavega.Pomace.Sweep.plist']:
            source = ROOT / relative
            self.assertTrue(source.is_file(), relative)
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
        self.script('swift', 'arch=""\nshow=0\n'
                    'while [ "$#" -gt 0 ]; do\n'
                    '  case "$1" in --arch) arch="$2"; shift;; --show-bin-path) show=1;; esac\n'
                    '  shift\ndone\n'
                    f'products="{self.products}"\n'
                    'if [ -z "$arch" ]; then\n  echo "$products"\n'
                    'elif [ "$show" = 1 ]; then\n  echo "$products/$arch"\nelse\n'
                    '  mkdir -p "$products/$arch"\n'
                    '  lipo "$products/PomaceApp" -thin "$arch" -output "$products/$arch/PomaceApp"\n'
                    '  rm -rf "$products/$arch/Pomace_PomaceApp.bundle"\n'
                    '  cp -R "$products/Pomace_PomaceApp.bundle" "$products/$arch/"\nfi')
        # Capture the app's load commands at signing time, before the build exits.
        self.script('codesign', 'case " $* " in *" --sign "*) ;; *) exit 0 ;; esac\n'
                    'for arg in "$@"; do\n'
                    '  case "$arg" in *.app)\n'
                    '    if [ -f "$arg/Contents/MacOS/Pomace" ] && [ ! -f "' + str(self.root / 'at-signing') + '" ]; then\n'
                    '      otool -l "$arg/Contents/MacOS/Pomace" > "' + str(self.root / 'at-signing') + '"\n'
                    '    fi ;; esac\ndone')

    def script(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)

    def build(self, config):
        return run('bash', str(self.root / 'build-app.sh'), config,
                   cwd=self.root, env=self.environment)

    def check_bundle(self):
        return subprocess.run(['bash', str(self.root / 'scripts/check-bundle.sh'),
                               '--universal', str(self.app)], env=self.environment,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_release_removes_toolchain_rpaths_before_signing(self):
        self.build('release')
        binary = self.app / 'Contents/MacOS/Pomace'
        self.assertEqual(set(rpaths(binary)), set(ALLOWED))
        at_signing = (self.root / 'at-signing').read_text()
        self.assertIn('cmd LC_RPATH', at_signing)
        for path in TOOLCHAIN:
            self.assertNotIn(path, at_signing)
        for path in ALLOWED:
            self.assertIn(f'path {path} (offset ', at_signing)
        # The SwiftPM product is shared build output and must remain untouched.
        self.assertEqual(set(rpaths(self.products / 'PomaceApp')), set(ALLOWED + TOOLCHAIN))

    def test_bundle_requires_plural_rules_in_every_locale(self):
        # Native SwiftPM uses a flat bundle; swift-build uses Contents/Resources.
        for layout in ['', 'Contents/Resources']:
            if layout:
                product = self.products / 'Pomace_PomaceApp.bundle'
                nested = product / layout
                nested.mkdir(parents=True)
                for directory in product.glob('*.lproj'):
                    shutil.move(directory, nested / directory.name)
            with self.subTest(layout=layout):
                self.build('release')
                result = self.check_bundle()
                self.assertEqual(result.returncode, 0, result.stdout)
                resources = self.app / 'Contents/Resources/Pomace_PomaceApp.bundle'
                locales = sorted((resources / layout).glob('*.lproj'))
                self.assertEqual(len(locales), 8)
                for directory in locales:
                    with self.subTest(locale=directory.name):
                        rules = directory / 'Localizable.stringsdict'
                        self.assertTrue(rules.is_file())
                        contents = rules.read_bytes()
                        rules.unlink()
                        result = self.check_bundle()
                        self.assertNotEqual(result.returncode, 0, result.stdout)
                        self.assertIn(f'{directory.name}/Localizable.stringsdict', result.stdout)
                        rules.write_bytes(contents)
                shutil.rmtree(resources)
                result = self.check_bundle()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('resource bundle', result.stdout)
                (resources / layout).mkdir(parents=True)
                result = self.check_bundle()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('no localized resources', result.stdout)

    def test_debug_keeps_toolchain_rpaths(self):
        self.build('debug')
        self.assertEqual(set(rpaths(self.app / 'Contents/MacOS/Pomace')),
                         set(ALLOWED + TOOLCHAIN))

    def test_bundle_rejects_absolute_non_system_rpaths(self):
        self.build('release')
        binary = self.app / 'Contents/MacOS/Pomace'
        # Normalize independently of the build cleanup so this tests the checker alone.
        for path in set(rpaths(binary)) - set(ALLOWED):
            run('install_name_tool', '-delete_rpath', path, str(binary))
        self.assertEqual(set(rpaths(binary)), set(ALLOWED))
        self.assertEqual(self.check_bundle().returncode, 0)
        for relative in ['Contents/MacOS/Pomace', 'Contents/Helpers/applesauce',
                         'Contents/Frameworks/Sparkle.framework/Sparkle',
                         'Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate',
                         'Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater',
                         'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer',
                         'Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader']:
            target = self.app / relative
            for path in TOOLCHAIN + ['/opt/host/lib', '/usr/library/not-system']:
                with self.subTest(binary=relative, path=path):
                    run('install_name_tool', '-add_rpath', path, str(target))
                    self.assertIn(path, rpaths(target))
                    result = self.check_bundle()
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn('absolute non-system rpath', result.stdout)
                    self.assertIn(path, result.stdout)
                    run('install_name_tool', '-delete_rpath', path, str(target))


if __name__ == '__main__':
    unittest.main()
