"""Route arithmetic for the generated site (ZDS 0015, Stable routes).

Every internal link is computed as a relative path between two routes. That is
what lets the same output tree serve correctly from a local root and from the
repository sub-path on GitHub Pages with no configuration and no `<base>`
element — and it is why no source file in this tree contains the deployment
path.

The one exception is the not-found document, which the host serves for a
request of unknown depth; a relative asset reference in it would resolve
against whatever directory the visitor happened to ask for. That page alone
gets base-absolute URLs, and the base comes from a build flag.
"""

from __future__ import annotations

import posixpath
import re
import unicodedata

_SLUG_STRIP = re.compile(r"[^a-z0-9]+")


def slugify(text: str) -> str:
    """A stable anchor from heading text.

    Typst identifies headings by position, so its own identifiers renumber
    whenever any earlier content changes — they cannot be anchors anyone links
    to. Slugging the text instead means an anchor survives an edit elsewhere
    in the document, which is the whole point of a permalink.
    """
    normalized = unicodedata.normalize("NFKD", text)
    ascii_text = normalized.encode("ascii", "ignore").decode("ascii").lower()
    slug = _SLUG_STRIP.sub("-", ascii_text).strip("-")
    return slug or "section"


def unique_slug(text: str, taken: set[str]) -> str:
    """`slugify`, disambiguated against slugs already used on the page."""
    base = slugify(text)
    if base not in taken:
        taken.add(base)
        return base
    for suffix in range(2, 1000):
        candidate = f"{base}-{suffix}"
        if candidate not in taken:
            taken.add(candidate)
            return candidate
    raise ValueError(f"cannot disambiguate the anchor {base!r}")


def normalize(route: str) -> str:
    """A route as this module handles them: no leading slash, directory
    routes ending in a slash, and the site root as the empty string."""
    return route.lstrip("/")


def output_path(route: str) -> str:
    """The file a route is written to.

    A directory-style route becomes `index.html` inside it, so the served URL
    keeps its trailing slash and relative links inside the page resolve
    against the directory rather than a sibling.
    """
    route = normalize(route)
    if route == "" or route.endswith("/"):
        return posixpath.join(route, "index.html")
    return route


def depth(route: str) -> int:
    """How many directories deep a route's *document* sits."""
    return output_path(route).count("/")


def relative(from_route: str, to: str) -> str:
    """A link from one route to another path, as a relative URL.

    `to` may be a route or an asset path; both are site-relative.
    """
    prefix = "../" * depth(from_route)
    target = normalize(to)
    if target == "":
        return prefix or "./"
    return (prefix + target) if prefix else target


def absolute(base: str, target: str) -> str:
    """A base-absolute URL, for the one document that cannot use a relative
    one. `base` is the deployment prefix, `/` or `/zenfmt/`."""
    if not base.startswith("/"):
        base = "/" + base
    if not base.endswith("/"):
        base += "/"
    return base + normalize(target)
