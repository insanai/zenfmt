"""Checks the assembled site before it is published (ZDS 0015).

These are the properties that are cheap to assert and expensive to discover
after a deploy: a link that resolves on a case-insensitive filesystem but not
on the server, a page that slipped an inline style past the transform, an
external request the policy does not permit.
"""

from __future__ import annotations

import re
from pathlib import Path

INLINE_STYLE = re.compile(r"<[^>]+\sstyle=", re.IGNORECASE)
STYLE_ELEMENT = re.compile(r"<style[\s>]", re.IGNORECASE)
EVENT_HANDLER = re.compile(r"<[^>]+\son[a-z]+=", re.IGNORECASE)
HREF = re.compile(r'(?:href|src)="([^"]+)"', re.IGNORECASE)
H1 = re.compile(r"<h1[\s>]", re.IGNORECASE)
IMG = re.compile(r"<img\b[^>]*>", re.IGNORECASE)
BANNED_LINK_TEXT = {"learn more", "click here", "here", "read more", "more"}
LINK_TEXT = re.compile(r"<a\b[^>]*>(.*?)</a>", re.IGNORECASE | re.DOTALL)
TAGS = re.compile(r"<[^>]+>")


def check(out: Path) -> list[str]:
    """Every problem found, so one run reports all of them rather than the
    first."""
    problems: list[str] = []
    documents = sorted(out.rglob("*.html"))
    if not documents:
        return [f"{out} contains no HTML"]

    present = {str(path.relative_to(out)) for path in out.rglob("*") if path.is_file()}

    for path in documents:
        name = str(path.relative_to(out))
        text = path.read_text(encoding="utf-8")
        problems += _check_policy(name, text)
        problems += _check_structure(name, text)
        problems += _check_links(name, text, present, out)
    return problems


def _check_policy(name: str, text: str) -> list[str]:
    problems = []
    if STYLE_ELEMENT.search(text):
        problems.append(f"{name}: contains a <style> element, which the policy forbids")
    if INLINE_STYLE.search(text):
        problems.append(
            f"{name}: contains an inline style attribute, which the policy forbids"
        )
    if EVENT_HANDLER.search(text):
        problems.append(f"{name}: contains an inline event handler")
    if "Content-Security-Policy" not in text:
        problems.append(f"{name}: has no content policy")
    return problems


def _check_structure(name: str, text: str) -> list[str]:
    problems = []
    headings = len(H1.findall(text))
    if headings != 1:
        problems.append(
            f"{name}: has {headings} top-level headings, expected exactly 1"
        )
    for image in IMG.findall(text):
        if "alt=" not in image:
            problems.append(f"{name}: an image has no alternative text")
    for raw in LINK_TEXT.findall(text):
        label = TAGS.sub("", raw).strip().lower().rstrip(".")
        if label in BANNED_LINK_TEXT:
            problems.append(
                f"{name}: a link reads {label!r}, which says nothing out of context"
            )
    return problems


def _check_links(name: str, text: str, present: set[str], out: Path) -> list[str]:
    problems = []
    document = out / name
    for target in HREF.findall(text):
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        if target.startswith("/"):
            # Only the not-found document may use a base-absolute URL, since
            # it is served for a path of unknown depth.
            if name != "404.html":
                problems.append(
                    f"{name}: {target!r} is base-absolute; use a relative link"
                )
            continue
        path, _, _fragment = target.partition("#")
        if not path:
            continue
        resolved = (document.parent / path).resolve()
        try:
            relative = str(resolved.relative_to(out.resolve()))
        except ValueError:
            problems.append(f"{name}: {target!r} escapes the output tree")
            continue
        # A directory-style link is served as the index inside it — including
        # a link to the site root, which resolves to the output directory
        # itself and would otherwise look like a missing file.
        if relative == ".":
            relative = "index.html"
        elif path.endswith("/") or resolved.is_dir():
            relative = f"{relative}/index.html"
        # Compared against the real file set rather than asked of the
        # filesystem, so a case difference that a case-insensitive developer
        # machine would hide is still a failure here.
        if relative not in present:
            problems.append(f"{name}: {target!r} does not resolve to a published file")
    return problems
