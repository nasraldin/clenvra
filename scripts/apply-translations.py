#!/usr/bin/env python3
"""Merges translation files (docs/engineering/translations/*.json) into the app's String Catalog.

Format per key: {"ar": "…"} | {"en_plural": {...}, "ar_plural": {...}} | {"doNotTranslate": true}
Usage: scripts/apply-translations.py [--overwrite] docs/engineering/translations/T11.json [more.json …]
Existing Arabic translations are kept (and reported) unless --overwrite is given, so one feature's file
cannot silently change wording another feature relies on.
"""
import json, sys

CATALOG = "Clenvra/Resources/Localizable.xcstrings"

def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}

def plural(forms):
    return {"variations": {"plural": {form: unit(text) for form, text in forms.items()}}}

overwrite = "--overwrite" in sys.argv
paths = [arg for arg in sys.argv[1:] if arg != "--overwrite"]
catalog = json.load(open(CATALOG))
strings = catalog["strings"]
kept = []
for path in paths:
    for key, spec in json.load(open(path)).items():
        entry = strings.setdefault(key, {})
        if not overwrite and "ar" in entry.get("localizations", {}) and not spec.get("doNotTranslate"):
            kept.append(key)
            continue
        if spec.get("doNotTranslate"):
            entry["shouldTranslate"] = False
            continue
        localizations = entry.setdefault("localizations", {})
        if "ar" in spec:
            localizations["ar"] = unit(spec["ar"])
        if "ar_plural" in spec:
            localizations["ar"] = plural(spec["ar_plural"])
        if "en_plural" in spec:
            localizations["en"] = plural(spec["en_plural"])

json.dump(catalog, open(CATALOG, "w"), ensure_ascii=False, indent=2, sort_keys=True)
if kept:
    print(f"Kept {len(kept)} existing translations (use --overwrite to replace): " + ", ".join(kept[:20]))
missing = [k for k, v in strings.items() if v.get("shouldTranslate", True) and "ar" not in v.get("localizations", {})]
print(f"{len(missing)} keys still need Arabic" + (": " + ", ".join(missing[:20]) if missing else ""))
