#!/usr/bin/env python3
"""Write each release's short update note into a Sparkle appcast.

usage: update-notes.py APPCAST NOTES_DIR

NOTES_DIR holds one folder per version (CFBundleShortVersionString), each with
a plain-text file per interface language. Every non-empty line is one line of
the note. An item whose version has a folder gets one <description> per
language, English first and unmarked so Sparkle falls back to it; items
without a folder are left as they are. A missing NOTES_DIR changes nothing.

Someone who skips releases sees what changed since their own version: the
item's note, then the earlier releases' notes, quieter, newest first. Sparkle
marks the block whose data-sparkle-version is the installed build
(CFBundleVersion, taken from the feed's items), and the style hides that block
and everything older. A folder with an own-note-only file is shown only as
that release's own note, never in another release's list (for a note such as
"Fixes and better stability." that names nothing a person can see).
"""

import html
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

LANGUAGES = ("en", "de", "es", "fr", "it", "zh-Hans", "zh-Hant")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
# Sparkle draws the note in its update window with the system font and its own
# dark-mode colors; this sets the spacing and quiets the earlier releases.
STYLE = (
    "<style>"
    "body{margin:0;padding:10px 12px;line-height:1.45}"
    "p{margin:0}p+p,div{margin-top:6px}div{opacity:.6}"
    ".sparkle-installed-version,.sparkle-installed-version~div{display:none}"
    "</style>"
)


def parts(version):
    return tuple(int(part) for part in version.split("."))


def lines(path):
    found = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not found:
        raise SystemExit(f"{path} is empty.")
    if len(found) > 3:
        raise SystemExit(f"{path} has {len(found)} lines; keep an update note to three at most.")
    return "".join(f"<p>{html.escape(line, quote=False)}</p>" for line in found)


def note_html(notes, builds, version, code):
    earlier = sorted((folder.name for folder in notes.iterdir()
                      if folder.is_dir() and parts(folder.name) < parts(version)
                      and not (folder / "own-note-only").exists()), key=parts, reverse=True)
    for name in earlier:
        if name not in builds:
            raise SystemExit(f"{notes / name} has no release in the feed.")
    return STYLE + lines(notes / version / f"{code}.txt") + "".join(
        f'<div data-sparkle-version="{builds[name]}">{lines(notes / name / f"{code}.txt")}</div>' for name in earlier)


def main():
    appcast, notes = Path(sys.argv[1]), Path(sys.argv[2])
    if not notes.is_dir():
        return
    for folder in (path for path in notes.iterdir() if path.is_dir()):
        missing = [code for code in LANGUAGES if not (folder / f"{code}.txt").is_file()]
        if missing:
            raise SystemExit(f"{folder} lacks {', '.join(f'{code}.txt' for code in missing)}.")
    ET.register_namespace("sparkle", SPARKLE)
    tree = ET.parse(appcast)
    cdata, written = {}, []
    builds = {item.findtext(f"{{{SPARKLE}}}shortVersionString"): item.findtext(f"{{{SPARKLE}}}version")
              for item in tree.getroot().iter("item")}
    for item in tree.getroot().iter("item"):
        version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
        folder = notes / (version or "")
        if not version or not folder.is_dir():
            continue
        written.append(version)
        for old in item.findall("description"):
            item.remove(old)
        position = list(item).index(item.find("title")) + 1
        for offset, code in enumerate(LANGUAGES):
            description = ET.Element("description")
            if code != "en":
                description.set(XML_LANG, code)
            token = f"@@note-{len(cdata)}@@"
            cdata[token] = note_html(notes, builds, version, code)
            description.text = token
            item.insert(position + offset, description)
    ET.indent(tree, space="    ")
    text = ET.tostring(tree.getroot(), encoding="unicode", xml_declaration=False).replace(" />", "/>")
    for token, value in cdata.items():
        text = text.replace(token, f"<![CDATA[{value}]]>")
    appcast.write_text('<?xml version="1.0" standalone="yes"?>\n' + text + "\n", encoding="utf-8")
    print(f"Update notes for {', '.join(written) or 'no item'}.")


if __name__ == "__main__":
    main()
