# Improving Pomace’s translations

Pomace supports English (`en`), Simplified Chinese (`zh-Hans`), Spanish (`es`), Japanese (`ja`), Korean (`ko`), German (`de`), French (`fr`) and Brazilian Portuguese (`pt-BR`). The seven translations are machine-made. Corrections from native speakers are welcome.

To suggest a correction, [open an issue](https://github.com/sdelavega/Pomace/issues/new) with the language, the current wording, your proposed wording and where it appears. A screenshot is helpful but optional. You can also send a pull request editing `Sources/PomaceApp/Resources/Localizable.xcstrings`. Mention the string key so the change is easy to review.

Read the key’s translator comment and, when needed, its Swift call site to understand what the user is doing. Convey the meaning naturally in that context rather than translating English word for word. Follow the [glossary](translations-glossary.md), use the terms macOS uses, and keep product names and command-line flags unchanged. Spanish uses tú; Japanese and Korean use polite neutral UI language. Report a composed phrase that cannot be made natural by changing its translation, with the key and language, so its caller can be improved.

Keep every `stringUnit.state` set to `translated`. Preserve format tokens exactly, including integer widths, repetitions and positional indices: `%@`, `%ld`, `%lld`, `%d`, `%1$@`, `%2$lld` and so on. Indexed placeholders may be reordered; unindexed placeholders must retain their argument order. `%%` displays a percent sign. Do not translate literal filesystem paths such as `/Applications`.

For plural entries, keep all cardinal categories required by the locale: `one` and `other` for English and German; `one`, `many` and `other` for Spanish, French and Brazilian Portuguese; only `other` for Chinese, Japanese and Korean. CLDR uses `many` for certain large numbers in es/fr/pt-BR; it usually has the same wording as `other`. French and Brazilian Portuguese also use `one` for zero, so choose wording that works for that category. Each variant must preserve the source’s format tokens.

Run these checks from the repository root:

```bash
python3 -m unittest discover -s scripts/tests -p test_check_l10n.py
python3 scripts/check-l10n.py lint
python3 scripts/check-l10n.py catalog --locales en zh-Hans es ja ko de fr pt-BR
```

The catalog check validates every requested locale, values, translation state, format-token multisets, plural categories, and catalog coverage of app source keys. The lint flags untranslated Swift UI literals, including picker and table headings, multiline Text, and open/save panel messages. The full `scripts/gate.sh` runs these checks alongside the build and integration suite.

For a visual check on macOS, build the app and launch a separate instance in a language, for example:

```bash
./build-app.sh release
open -n build/Pomace.app --args -AppleLanguages '(de)'
```

Check the main window, Settings → Advanced, onboarding, singular and plural counts, and longer error messages. Launch with `-NSDoubleLocalizedStrings YES` to check length expansion. Automated screenshots must use existing permissions; do not request new Screen Recording or Accessibility access just to capture them.
