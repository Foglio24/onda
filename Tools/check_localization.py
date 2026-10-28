"""Checks the app's English text against the strings the Swift compiler found in the code.

Usage: check_localization.py <derived data dir> <en Localizable.strings> <Seaglass.app>

With SWIFT_EMIT_LOC_STRINGS the compiler writes a .stringsdata file for each Swift file,
listing its localizable strings (Text("…"), Label("…"), String(localized: "…")…) with
interpolations turned into format specifiers. The keys are the Italian text, so each one
needs an English entry. The check fails when one is missing, when an English entry matches
no key (a typo, or text changed in the code), when an entry's format specifiers differ from
its key's, or when the app lacks its Italian or English strings.
"""

import glob
import json
import os
import re
import sys

SPECIFIER = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%]")


def parse_strings(text):
    """Entries of a "key" = "value"; strings file, in order."""
    tokens = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
        elif text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
        elif c == '"':
            j = i + 1
            chars = []
            while text[j] != '"':
                if text[j] == "\\":
                    chars.append({"n": "\n", "t": "\t"}.get(text[j + 1], text[j + 1]))
                    j += 2
                else:
                    chars.append(text[j])
                    j += 1
            tokens.append(("string", "".join(chars)))
            i = j + 1
        elif c in "=;":
            tokens.append((c, c))
            i += 1
        else:
            raise ValueError(f"unexpected {c!r} at offset {i}")
    entries = []
    for k in range(0, len(tokens), 4):
        group = tokens[k:k + 4]
        kinds = [kind for kind, _ in group]
        if kinds != ["string", "=", "string", ";"]:
            raise ValueError(f"malformed entry near {group!r}")
        entries.append((group[0][1], group[2][1]))
    return entries


def compiler_keys(derived_data):
    """Localizable keys of the app target, with the Swift file each comes from."""
    paths = [p for p in glob.glob(os.path.join(derived_data, "**", "*.stringsdata"), recursive=True)
             if f"{os.sep}Seaglass.build{os.sep}" in p]
    if not paths:
        sys.exit(f"::error::No .stringsdata files under {derived_data}: is SWIFT_EMIT_LOC_STRINGS on?")
    keys = {}
    for path in sorted(paths):
        with open(path, "rb") as handle:
            raw = handle.read()
        try:
            data = json.loads(raw)
        except ValueError:
            sys.exit(f"::error::{path} is not JSON: {raw[:300]!r}")
        source = os.path.basename(data.get("source", path))
        for entry in data.get("tables", {}).get("Localizable", []):
            if not isinstance(entry, dict) or "key" not in entry:
                sys.exit(f"::error::Unexpected entry in {path}: {entry!r}")
            keys.setdefault(entry["key"], source)
    return keys


def has_words(key):
    return any(c.isalpha() for c in SPECIFIER.sub("", key))


def main():
    derived_data, english_path, app = sys.argv[1:4]
    with open(english_path, encoding="utf-8") as handle:
        entries = parse_strings(handle.read())
    english = {}
    problems = []
    for key, value in entries:
        if key in english:
            problems.append(f"Listed twice in en.lproj: {key!r}")
        english[key] = value
        if sorted(SPECIFIER.findall(key)) != sorted(SPECIFIER.findall(value)):
            problems.append(f"Format specifiers differ: {key!r} = {value!r}")

    keys = compiler_keys(derived_data)
    for key, source in sorted(keys.items(), key=lambda item: (item[1], item[0])):
        if has_words(key) and key not in english:
            problems.append(f"No English for {key!r} ({source})")
    for key in english:
        if key not in keys:
            problems.append(f"English entry matches no text in the code: {key!r}")

    for language in ("it", "en"):
        if not os.path.exists(os.path.join(app, f"{language}.lproj", "Localizable.strings")):
            problems.append(f"The app has no {language}.lproj/Localizable.strings")

    print(f"{len(keys)} localizable strings in the code, {len(english)} English entries.")
    for problem in problems:
        print(f"::error::{problem}")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
