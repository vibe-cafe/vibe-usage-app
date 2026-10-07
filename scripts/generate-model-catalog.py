#!/usr/bin/env python3
"""Regenerate VibeUsage/Models/ModelCatalog.generated.swift from models.dev.

models.dev (https://models.dev, open source) publishes every provider's model
ids together with their official display names. Two tables are emitted:

- names: display names from first-party providers (plus a few curated
  aggregators as fallback). Third-party resellers often re-spell names
  ("Gemini-3-Flash", "Kimi K3 TEE"), so earlier providers in PROVIDERS win.
- aliases: every provider's own spelling of a model ("google.gemma-3-27b-it",
  "k3-256k") mapped to the names key of the model it serves, taken from
  models.dev's hand-curated `canonical_model_id`. A spelling that different
  providers point at different models is ambiguous and dropped, so the app
  shows the raw id instead of guessing.

`normalize` must stay in sync with DisplayNames.normalizedID in the app.

Usage:
    python3 scripts/generate-model-catalog.py              # fetch live
    python3 scripts/generate-model-catalog.py --input api.json
"""

import argparse
import datetime
import json
import pathlib
import re
import urllib.request

SOURCE_URL = "https://models.dev/api.json"
OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "VibeUsage/Models/ModelCatalog.generated.swift"

# Highest priority first. First-party labs, then coding-plan / agent gateways
# that host their own models, then OpenRouter as a broad, well-normalized fallback.
PROVIDERS = [
    "anthropic", "openai", "google", "xai", "deepseek", "moonshotai", "zhipuai", "zai",
    "alibaba", "minimax", "xiaomi", "mistral", "meta", "cohere", "stepfun-ai",
    "tencent-tokenhub", "volcengine", "inception", "ai21", "perplexity", "longcat",
    "kimi-code-plan-global", "opencode", "opencode-go",
    "openrouter",
]


# Rolling aliases ("devstral-medium-latest", "kimi-latest") point at whatever
# model is current, so their name says nothing about historical usage.
ROLLING_ALIAS = re.compile(r"(^|[-.])latest($|[-.])")

# Mirrors DisplayNames.droppedTags / vendorPrefix / noisePatterns in the app.
DROPPED_TAGS = {"free", "beta", "exacto", "nitro", "floor", "extended", "online"}
VENDOR_PREFIX = re.compile(
    r"^(anthropic|google|meta|mistral|amazon|deepseek|moonshotai|openai|qwen|minimax|xiaomi"
    r"|zai|cohere|nvidia|ai21|writer|us|eu|apac|global|jp|au)\.")
NOISE_PATTERNS = [
    re.compile(r"-\d{8}-v\d+$"),
    re.compile(r"-\d{8}$"),
    re.compile(r"-\d{4}-\d{2}-\d{2}$"),
    re.compile(r"-expires-on-\d+$"),
    re.compile(r"-\d+[km]$"),
]


def strip_noise(s: str) -> str:
    changed = True
    while changed:
        changed = False
        for pattern in NOISE_PATTERNS:
            match = pattern.search(s)
            if match and match.start() > 0:
                s = s[: match.start()]
                changed = True
    return s


def normalize(raw: str) -> str:
    s = raw.strip().lower().rsplit("/", 1)[-1]
    if ":" in s:
        base, tag = s.split(":", 1)
        s = base if tag.isdigit() or tag in DROPPED_TAGS else f"{base}-{tag.replace(':', '-')}"
    at = s.find("@")
    if at > 0:
        s = s[:at]
    while VENDOR_PREFIX.match(s):
        s = VENDOR_PREFIX.sub("", s, count=1)
    return strip_noise(s)


def swift_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def build_names(data: dict) -> dict[str, str]:
    table: dict[str, str] = {}
    for provider in PROVIDERS:
        models = data.get(provider, {}).get("models", {})
        for model_id, model in sorted(models.items()):
            if ROLLING_ALIAS.search(model_id.lower()):
                continue
            name = (model.get("name") or "").strip()
            # Rolling aliases are labelled "Claude Opus 4.5 (latest)"; the
            # dashboard wants the model's own name.
            name = name.removesuffix(" (latest)").strip()
            if ":" in model_id:
                # Reseller variants such as "x:free" are not ids tools report.
                continue
            # Aggregators namespace ids as "vendor/model"; the app strips the
            # same prefix before lookup, so key on the last segment.
            key = model_id.rsplit("/", 1)[-1].lower()
            bare = model_id.rsplit("/", 1)[-1]
            if not name or (name == bare and bare == bare.lower()):
                # An all-lowercase "name" that repeats the id carries no casing
                # info ("kimi-for-coding"); "MiniMax-M2.7-highspeed" still does.
                continue
            table.setdefault(key, name)
            # The app looks ids up after dropping dates and context sizes.
            table.setdefault(normalize(model_id), name)
    return table


def build_aliases(data: dict, names: dict[str, str], skip_providers: frozenset = frozenset()) -> dict[str, str]:
    targets: dict[str, set[str]] = {}
    for provider, info in data.items():
        if provider in skip_providers:
            continue
        for model_id, model in info.get("models", {}).items():
            canonical = model.get("canonical_model_id")
            if not canonical or ROLLING_ALIAS.search(model_id.lower()):
                continue
            key = normalize(model_id)
            target = canonical.rsplit("/", 1)[-1].lower()
            if target not in names:
                target = normalize(canonical)
            if not key or target not in names or key == target:
                continue
            targets.setdefault(key, set()).add(target)
    # Distinct targets with the same display name are snapshots of one model.
    return {
        key: sorted(found)[0]
        for key, found in targets.items()
        if key not in names and len({names[t] for t in found}) == 1
    }


def render(names: dict[str, str], aliases: dict[str, str]) -> str:
    today = datetime.date.today().isoformat()
    lines = [
        "// Generated by scripts/generate-model-catalog.py from https://models.dev — do not edit.",
        f"// Snapshot: {today}, {len(names)} names, {len(aliases)} aliases.",
        "",
        "enum ModelCatalog {",
        "    /// Lowercased model id (provider prefix removed) → official display name.",
        "    static let names: [String: String] = [",
    ]
    for key in sorted(names):
        lines.append(f"        {swift_string(key)}: {swift_string(names[key])},")
    lines += [
        "    ]",
        "",
        "    /// Normalized provider-specific id → `names` key of the model it serves.",
        "    static let aliases: [String: String] = [",
    ]
    for key in sorted(aliases):
        lines.append(f"        {swift_string(key)}: {swift_string(aliases[key])},")
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", help="Read a saved api.json instead of fetching it")
    args = parser.parse_args()

    if args.input:
        data = json.loads(pathlib.Path(args.input).read_text())
    else:
        # models.dev rejects urllib's default User-Agent with 403.
        request = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "vibe-usage-app model catalog generator"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = json.load(response)

    names = build_names(data)
    aliases = build_aliases(data, names)
    OUTPUT.write_text(render(names, aliases))
    print(f"Wrote {len(names)} names and {len(aliases)} aliases to {OUTPUT.relative_to(OUTPUT.parent.parent.parent)}")


if __name__ == "__main__":
    main()
