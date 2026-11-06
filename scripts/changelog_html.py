#!/usr/bin/env python3
"""Print one CHANGELOG.md version section as minimal HTML (Sparkle release notes).

    scripts/changelog_html.py 1.1.0 < CHANGELOG.md
"""
import html
import re
import sys

version = sys.argv[1]
lines = sys.stdin.read().splitlines()
section, inside = [], False
for line in lines:
    if re.match(r"^## \[" + re.escape(version) + r"\]", line):
        inside = True
        continue
    if inside and line.startswith("---"):
        break
    if inside:
        section.append(line)

def inline(text):
    text = html.escape(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    return re.sub(r"\[(.+?)\]\((.+?)\)", r'<a href="\2">\1</a>', text)

out, in_list = ["<html><body style=\"font-family:-apple-system;font-size:13px\">"], False
for line in section:
    stripped = line.strip()
    if stripped.startswith("### Installation"):
        break  # install steps are for the download page, not the update dialog
    if stripped.startswith("- "):
        if not in_list:
            out.append("<ul>"); in_list = True
        out.append(f"<li>{inline(stripped[2:])}</li>")
        continue
    if in_list:
        out.append("</ul>"); in_list = False
    if stripped.startswith("### "):
        out.append(f"<h3>{inline(stripped[4:])}</h3>")
    elif stripped:
        out.append(f"<p>{inline(stripped)}</p>")
if in_list:
    out.append("</ul>")
out.append("</body></html>")
print("\n".join(out))
