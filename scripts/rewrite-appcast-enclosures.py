#!/usr/bin/env python3
"""Rewrite Sparkle appcast <enclosure url> entries so every item points at its
own immutable per-tag GitHub release asset, never at the "latest" alias.

Sparkle's `generate_appcast` only sets the requested `--download-url-prefix`
on the item(s) it creates in a given run; it reuses and rewrites the existing
appcast.xml in place, so an older item that was ever generated (or hand-set)
with a `releases/latest/download/...` enclosure URL keeps that URL forever.
Once GitHub repoints the "latest" alias at a newer release, that old item's
EdDSA signature (computed over the old ZIP's bytes) stops matching whatever
bytes "latest" now serves, and Sparkle refuses the update with "The update is
improperly signed and could not be validated." (confirmed 2026-09-18).

This script is idempotent: items already pointing at a per-tag URL are left
untouched, and it is safe to run on every appcast.xml before publishing.

Usage:
    rewrite-appcast-enclosures.py <appcast.xml> <repo-releases-base-url>

Exits non-zero (after printing what's wrong) if:
  - an item has no `sparkle:shortVersionString` to derive a tag from, or
  - after rewriting, any enclosure URL still contains
    "releases/latest/download/".
"""
import re
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("", "")


def sparkle_tag(name: str) -> str:
    return f"{{{SPARKLE_NS}}}{name}"


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <appcast.xml> <repo-releases-base-url>", file=sys.stderr)
        return 2

    appcast_path, releases_base = sys.argv[1], sys.argv[2].rstrip("/")

    tree = ET.parse(appcast_path)
    root = tree.getroot()
    items = root.findall("./channel/item")

    rewritten = 0
    errors = []

    for item in items:
        enclosure = item.find("enclosure")
        if enclosure is None:
            continue
        url = enclosure.get("url", "")
        if "releases/latest/download/" not in url:
            continue

        short_version_el = item.find(sparkle_tag("shortVersionString"))
        title_el = item.find("title")
        version_text = short_version_el.text.strip() if short_version_el is not None and short_version_el.text else None
        if not version_text:
            # Fall back to <title> only if it looks like a bare version number
            # (avoids guessing from free-text titles).
            if title_el is not None and title_el.text and re.fullmatch(r"[0-9][0-9.]*", title_el.text.strip()):
                version_text = title_el.text.strip()

        if not version_text:
            errors.append(
                f"item with enclosure url={url!r} has no usable "
                "sparkle:shortVersionString (and no bare-version <title>) to derive a release tag from"
            )
            continue

        filename = url.rsplit("/", 1)[-1]
        new_url = f"{releases_base}/download/v{version_text}/{filename}"
        enclosure.set("url", new_url)
        rewritten += 1
        print(f"    {url} -> {new_url}")

    print(f"==> Rewrote {rewritten} legacy 'latest' enclosure URL(s).")

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        return 1

    tree.write(appcast_path, xml_declaration=True, encoding="UTF-8")

    # Final guard: nothing should still point at the "latest" alias.
    with open(appcast_path, "r", encoding="utf-8") as f:
        contents = f.read()
    if "releases/latest/download/" in contents:
        print(
            "ERROR: appcast.xml still contains a 'releases/latest/download/' "
            "enclosure URL after rewriting.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
