#!/usr/bin/env python3
# Checks app literals and catalog coverage without requiring Xcode extraction.
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys


LITERAL_CALL = re.compile(r'(?<![\w])(?:Text|Button|Label|Toggle|Section|Picker|TableColumn|ContentUnavailableView|\.help|\.navigationTitle|\.accessibilityLabel)\s*\(\s*"')
KEY_CALL = re.compile(r'(?:\bNSLocalizedString|\bLocalizedStringKey|\bAppStrings\.text|\btext)\s*\(\s*"([^"\\]+)"|\b(?:Text|String)\s*\(\s*(?:localized:\s*)?"([^"\\]+)"')

# Cardinal categories used by the eight supported locales (CLDR).
PLURAL_CATEGORIES = {
    'en': {'one', 'other'}, 'zh-Hans': {'other'}, 'es': {'one', 'many', 'other'},
    'ja': {'other'}, 'ko': {'other'}, 'de': {'one', 'other'},
    'fr': {'one', 'many', 'other'}, 'pt-BR': {'one', 'many', 'other'},
}
FORMAT_SPECIFIER = re.compile(r'%%|%(?:\d+\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp]')
PANEL_ASSIGNMENT = re.compile(r'\b(\w+)\.(?:prompt|message)\s*=\s*"')


def string_end(source, start):
    """Skip a Swift string, including quotes inside interpolation expressions."""
    delimiter = '"""' if source.startswith('"""', start) else '"'
    i = start + len(delimiter)
    while i < len(source):
        if source.startswith(delimiter, i):
            return i + len(delimiter)
        if source.startswith('\\(', i):
            i = call_end(source, i + 1)
        elif source[i] == '\\':
            i += 2
        else:
            i += 1
    return len(source)


def call_end(source, start):
    depth = 1
    i = start + 1
    while i < len(source) and depth:
        if source[i] == '"':
            i = string_end(source, i)
            continue
        if source[i] == '(':
            depth += 1
        elif source[i] == ')':
            depth -= 1
        i += 1
    return i


def code_only(source):
    """Blank comments while preserving offsets and string literals."""
    result = list(source)
    i = 0
    while i < len(source):
        if source[i] == '"':
            i = string_end(source, i)
        elif source.startswith('//', i):
            end = source.find('\n', i)
            end = len(source) if end == -1 else end
            result[i:end] = ' ' * (end - i)
            i = end
        elif source.startswith('/*', i):
            start = i
            depth = 1
            i += 2
            while i < len(source) and depth:
                if source.startswith('/*', i):
                    depth += 1
                    i += 2
                elif source.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            result[start:i] = ['\n' if c == '\n' else ' ' for c in source[start:i]]
        else:
            i += 1
    return ''.join(result)


def source_calls(source, pattern):
    code = code_only(source)
    # Only consider call sites in code, never call-shaped text inside a string.
    i = 0
    while i < len(code):
        match = pattern.match(code, i)
        if match:
            opening = code.index('(', match.start())
            yield match, code[opening:call_end(code, opening)]
        if code[i] == '"':
            i = string_end(code, i)
        else:
            i += 1


def panel_assignments(source):
    code = code_only(source)
    panels = set(re.findall(r'\b(?:let|var)\s+(\w+)\s*(?::\s*NS(?:Open|Save)Panel\s*)?=\s*NS(?:Open|Save)Panel\s*\(', code))
    i = 0
    while i < len(code):
        match = PANEL_ASSIGNMENT.match(code, i)
        if match and match.group(1) in panels:
            yield match, ''
        if code[i] == '"':
            i = string_end(code, i)
        else:
            i += 1


def lint(root):
    errors = []
    for path in sorted((root / 'Sources/PomaceApp').rglob('*.swift')):
        source = path.read_text()
        for match, call in [*source_calls(source, LITERAL_CALL), *panel_assignments(source)]:
            line = source.count('\n', 0, match.start()) + 1
            original = source.splitlines()[line - 1]
            if re.search(r'//\s*l10n-exempt:\s*\S', original):
                continue
            if re.search(r'\bbundle:\s*\.module\b', call):
                continue
            # Text punctuation and symbols carry no words for a translator.
            if match.group().lstrip().startswith('Text'):
                start = match.end() - 1
                delimiter = '"""' if source.startswith('"""', start) else '"'
                literal = source[start + len(delimiter):string_end(source, start) - len(delimiter)]
                if not any(character.isalpha() for character in literal):
                    continue
            errors.append(f'{path.relative_to(root)}:{line}: localize user-visible literal')
    return errors


def specifiers(value):
    return Counter(token for token in FORMAT_SPECIFIER.findall(value) if token != '%%')


def check_translation(node, source, locale, label):
    errors = []
    if 'variations' in source:
        source_variants = source['variations'].get('plural', {})
        variants = node.get('variations', {}).get('plural', {})
        for category in sorted(PLURAL_CATEGORIES[locale] - variants.keys()):
            errors.append(f'{label}: missing {locale} plural category {category}')
        for category, variant in variants.items():
            baseline = source_variants.get(category, source_variants.get('other', {}))
            errors += check_translation(variant, baseline, locale, f'{label}/{category}')
        return errors
    unit = node.get('stringUnit', {})
    value = unit.get('value')
    if not isinstance(value, str) or not value:
        errors.append(f'{label}: missing {locale} value')
    else:
        baseline = source.get('stringUnit', {}).get('value', '')
        if specifiers(value) != specifiers(baseline):
            errors.append(f'{label}: {locale} format specifier multiset differs from en')
    if unit.get('state') != 'translated':
        errors.append(f'{label}: {locale} state must be translated')
    source_substitutions = source.get('substitutions', {})
    for name, substitution in source_substitutions.items():
        errors += check_translation(node.get('substitutions', {}).get(name, {}),
                                    substitution, locale, f'{label}/{name}')
    return errors


def catalog(root, locales):
    path = root / 'Sources/PomaceApp/Resources/Localizable.xcstrings'
    strings = json.loads(path.read_text())['strings']
    errors = []
    for locale in locales:
        if locale not in PLURAL_CATEGORIES:
            errors.append(f'unsupported locale: {locale}')
    for key, entry in strings.items():
        translations = entry.get('localizations', {})
        source = translations.get('en', {})
        for locale in dict.fromkeys(['en', *locales]):
            if locale in PLURAL_CATEGORIES:
                errors += check_translation(translations.get(locale, {}), source, locale, key)
    for source_path in sorted((root / 'Sources/PomaceApp').rglob('*.swift')):
        source = source_path.read_text()
        for match, call in source_calls(source, KEY_CALL):
            key = match.group(1) or match.group(2)
            if match.group(2) and not re.search(r'\bbundle:\s*\.module\b', call):
                continue
            if match.group().startswith('text') and source_path.name != 'Localized.swift':
                continue
            if key not in strings:
                line = source.count('\n', 0, match.start()) + 1
                errors.append(f'{source_path.relative_to(root)}:{line}: missing catalog key {key}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['lint', 'catalog'])
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--locales', nargs='+', default=['en'])
    args = parser.parse_args()
    try:
        errors = lint(args.root) if args.mode == 'lint' else catalog(args.root, args.locales)
    except (OSError, ValueError, KeyError) as error:
        errors = [str(error)]
    for error in errors:
        print(error, file=sys.stderr)
    return bool(errors)


if __name__ == '__main__':
    sys.exit(main())
