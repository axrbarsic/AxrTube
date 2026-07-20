#!/usr/bin/env python3
"""
Automate localization for Localizable.xcstrings.

- Adds Serbian (sr) and Croatian (hr) translations for all keys.
- Fills the 19 untranslated keys in every other language.
- Protects format specifiers (%@, %lld, %.2g, etc.) during translation.

Usage:
    /tmp/loctranslate_venv/bin/python3 translate_strings.py [--dry-run]
"""

import json
import re
import sys
import time
from pathlib import Path

XCSTRINGS_PATH = Path(__file__).parent / "Localizable.xcstrings"

# xcstrings lang code → GoogleTranslator lang code
LANG_MAP = {
    "ar":      "ar",
    "de":      "de",
    "es":      "es",
    "fr":      "fr",
    "hi":      "hi",
    "id":      "id",
    "it":      "it",
    "ja":      "ja",
    "ko":      "ko",
    "pt-BR":   "pt",
    "ru":      "ru",
    "tr":      "tr",
    "zh-Hans": "zh-CN",
    "sr":      "sr",
    "hr":      "hr",
}

# These keys carry no meaningful text to translate
SKIP_KEYS = {"", "%lld", "%lld s"}

# Regex to find printf-style format specifiers and keep them safe
FORMAT_SPEC_RE = re.compile(r'(%(?:\.\d+)?[diouxXeEfgGs@%]|%lld|%\d+\$[diouxXeEfgGs@]|%0\d+[d])')

# Use bracket tokens that are symbols — won't be transliterated by any script
_OPEN = "\u27ea"   # ⟪
_CLOSE = "\u27eb"  # ⟫

def protect_format_specs(text: str) -> tuple[str, list[str]]:
    """Replace format specifiers with unique symbol-bracket placeholders."""
    placeholders: list[str] = []

    def replacer(m: re.Match) -> str:
        idx = len(placeholders)
        placeholders.append(m.group(0))
        return f"{_OPEN}{idx}{_CLOSE}"

    protected = FORMAT_SPEC_RE.sub(replacer, text)
    return protected, placeholders


def restore_format_specs(text: str, placeholders: list[str]) -> str:
    for idx, spec in enumerate(placeholders):
        text = text.replace(f"{_OPEN}{idx}{_CLOSE}", spec)
    return text


def translate(text: str, target_lang: str, translator_cls) -> str:
    """Translate text to target_lang, preserving format specifiers."""
    if not text.strip():
        return text

    protected, placeholders = protect_format_specs(text)

    # If only format specifiers remain, no need to translate
    cleaned = FORMAT_SPEC_RE.sub("", protected).strip()
    if not cleaned:
        return text

    try:
        t = translator_cls(source="en", target=target_lang)
        result = t.translate(protected)
        return restore_format_specs(result, placeholders)
    except Exception as exc:
        print(f"    WARNING: translation failed ({exc}), keeping original", file=sys.stderr)
        return text


def main():
    dry_run = "--dry-run" in sys.argv
    # --fix-lang sr  → force-retranslate every key for that language
    fix_lang: str | None = None
    if "--fix-lang" in sys.argv:
        idx = sys.argv.index("--fix-lang")
        fix_lang = sys.argv[idx + 1] if idx + 1 < len(sys.argv) else None

    try:
        from deep_translator import GoogleTranslator
    except ImportError:
        print("ERROR: deep-translator not installed. Run:")
        print("  /tmp/loctranslate_venv/bin/pip install deep-translator")
        sys.exit(1)

    with open(XCSTRINGS_PATH, encoding="utf-8") as f:
        data = json.load(f)

    strings: dict = data["strings"]
    all_langs = list(LANG_MAP.keys())

    total_translated = 0
    total_skipped = 0

    for key, entry in strings.items():
        if key in SKIP_KEYS:
            total_skipped += 1
            continue

        locs: dict = entry.setdefault("localizations", {})

        for xcstrings_lang, google_lang in LANG_MAP.items():
            force = fix_lang == xcstrings_lang
            if xcstrings_lang in locs and not force:
                continue  # already translated

            # Determine source text: the key itself is the English string
            source_text = key

            print(f"  [{xcstrings_lang}] {repr(source_text)[:60]} …")

            if dry_run:
                translated_value = f"[{xcstrings_lang}] {source_text}"
            else:
                translated_value = translate(source_text, google_lang, GoogleTranslator)
                time.sleep(0.15)  # gentle rate limiting

            locs[xcstrings_lang] = {
                "stringUnit": {
                    "state": "translated",
                    "value": translated_value,
                }
            }
            total_translated += 1

    print(f"\nDone: {total_translated} translations added, {total_skipped} keys skipped.")

    if dry_run:
        print("(dry-run — file not written)")
        return

    # Write back with the same formatting as Xcode produces
    output = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=False)
    with open(XCSTRINGS_PATH, "w", encoding="utf-8") as f:
        f.write(output)
        f.write("\n")

    print(f"Written: {XCSTRINGS_PATH}")


if __name__ == "__main__":
    main()
