#!/usr/bin/env python3
# Checks app literals and catalog coverage without requiring Xcode extraction.
import argparse
import json
from pathlib import Path
import re
import sys


LITERAL_CALL = re.compile(r'(?<![\w])(?:Text|Button|Label|Toggle|Section|\.help|\.navigationTitle|\.accessibilityLabel)\s*\(\s*"')
KEY_CALL = re.compile(r'(?:\bNSLocalizedString|\bLocalizedStringKey|\bAppStrings\.text|\btext)\s*\(\s*"([^"\\]+)"|\b(?:Text|String)\s*\(\s*(?:localized:\s*)?"([^"\\]+)"')


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


def lint(root):
    errors = []
    for path in sorted((root / 'Sources/PomaceApp').rglob('*.swift')):
        source = path.read_text()
        for match, call in source_calls(source, LITERAL_CALL):
            line = source.count('\n', 0, match.start()) + 1
            original = source.splitlines()[line - 1]
            if re.search(r'//\s*l10n-exempt:\s*\S', original):
                continue
            if re.search(r'\bbundle:\s*\.module\b', call):
                continue
            # Text punctuation and symbols carry no words for a translator.
            if match.group().lstrip().startswith('Text') and not source[match.end():match.end() + 1].isalpha():
                continue
            errors.append(f'{path.relative_to(root)}:{line}: localize user-visible literal')
    return errors


def has_english(node):
    if 'stringUnit' in node:
        value = node['stringUnit'].get('value')
        return isinstance(value, str) and bool(value)
    if 'variations' in node:
        variants = node['variations'].get('plural', {})
        return 'other' in variants and all(has_english(v) for v in variants.values())
    if 'substitutions' in node:
        return bool(node['substitutions']) and all(has_english(v) for v in node['substitutions'].values())
    return False


def catalog(root, locales):
    path = root / 'Sources/PomaceApp/Resources/Localizable.xcstrings'
    strings = json.loads(path.read_text())['strings']
    errors = []
    for key, entry in strings.items():
        if not has_english(entry.get('localizations', {}).get('en', {})):
            errors.append(f'{key}: missing en value')
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
