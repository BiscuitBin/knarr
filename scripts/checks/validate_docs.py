"""Validate the handbook: manifest agreement, link integrity, and reachability.

The contract exists so documentation cannot quietly rot. Every page is
registered once, owns its topics, repeats its metadata in frontmatter, and is
reachable from the index.

Copied from github.com/steven-cutting/biscuit_games_tooling at v0.3.0
(6c5c07f6bec86e86b3930dfa41392e4b440e8c85),
src/biscuit_games_tooling/validate_docs.py. Adapted on 2026-10-07 for
checks.toml, manifest-only HTML metadata, strict field validation, rendered
Markdown navigation, and file-read diagnostics (Decision 0004).

SPDX-License-Identifier: Apache-2.0
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import deque
from contextlib import suppress
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from urllib.parse import unquote

import _project
import _tools

REQUIRED_FIELDS = {"path", "title", "kind", "audience", "canonical_for", "requires"}
METADATA_FIELDS = {"title", "kind", "audience", "canonical_for", "requires"}
KINDS = {"project", "tutorial", "how-to", "explanation", "reference", "operations", "decision"}
AUDIENCES = {"user", "contributor", "maintainer", "operator", "agent"}
# The predicates a page's `requires` may name come from the consumer's
# checks.toml, `[docs] predicates`, each true when
# enabled. A repository with no feature toggles declares none, and `requires` is
# still parsed and compared, so adding a predicate later is a one-line change
# there rather than a reshaping of the manifest.
MINIMUM_WORDS = 40
URL_SCHEME = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")

BAD_CONTENT = {
    "unresolved template syntax": re.compile(r"{" + r"{|{" + r"%|{" + r"#"),
    # The marker has to look like an annotation -- `TODO:`, `FIXME -`, or alone
    # at the end of a line. A page that discusses to-do markers as a subject is
    # describing them, not leaving itself a note.
    "an unfinished marker": re.compile(r"\b(?:TODO|TBD|FIXME)\b(?=\s*[:(\-]|\s*$)", re.MULTILINE),
    "placeholder prose": re.compile(r"\blorem ipsum\b|\binsert .{0,30} here\b", re.IGNORECASE),
}


class _Document(HTMLParser):
    """Navigation and headings from HTML, including rendered Markdown.

    The Markdown parser escapes code examples and leaves comments as comments,
    so neither can manufacture a navigation edge or a heading anchor.
    """

    def __init__(self) -> None:
        super().__init__()
        self.targets: list[str] = []
        self.anchors: set[str] = set()
        self.headings: list[tuple[int, str]] = []
        self.heading_tag: str | None = None
        self.heading_text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        for key, value in attrs:
            if value is not None:
                if key == "id" or (tag == "a" and key == "name"):
                    self.anchors.add(value)
                if tag == "a" and key == "href":
                    self.targets.append(value)
                if tag == "img" and key == "alt" and self.heading_tag:
                    self.heading_text.append(value)
        if re.fullmatch(r"h[1-6]", tag):
            self.heading_tag = tag
            self.heading_text = []

    def handle_data(self, data: str) -> None:
        if self.heading_tag:
            self.heading_text.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == self.heading_tag:
            self.headings.append((int(tag[1]), "".join(self.heading_text).strip()))
            self.heading_tag = None


def _documents(texts: dict[Path, str], errors: list[str]) -> dict[Path, _Document]:
    markdown = {}
    for path, text in texts.items():
        if path.suffix.lower() == ".md":
            # Frontmatter is metadata, not rendered body content. Invalid
            # frontmatter is diagnosed separately by _check_page.
            body = text
            with suppress(ValueError):
                _, body = _parse_frontmatter(text)
            markdown[str(path)] = body
    rendered = {}
    if markdown:
        checker = Path(__file__).resolve()
        try:
            result = subprocess.run(
                [
                    str(_tools.tool(checker.parents[2], "node")),
                    str(checker.with_name("render_markdown.mjs")),
                    str(_tools.tool(checker.parents[2], "markdownlint-cli2")),
                ],
                input=json.dumps(markdown),
                capture_output=True,
                text=True,
                check=True,
            )
            rendered = json.loads(result.stdout)
        except (OSError, subprocess.CalledProcessError, ValueError) as error:
            errors.append(f"Markdown parser unavailable; run just initialize: {error}")
            return {}
    documents = {}
    for path, text in texts.items():
        document = _Document()
        document.feed(rendered.get(str(path), text))
        if path.suffix.lower() == ".md":
            document.anchors.update(_anchors(document.headings))
        documents[path] = document
    return documents


def _parse_list(value: str) -> list[str]:
    if not (value.startswith("[") and value.endswith("]")):
        message = "expected an inline list"
        raise ValueError(message)
    body = value[1:-1].strip()
    return [item.strip().strip("\"'") for item in body.split(",")] if body else []


def _parse_frontmatter(text: str) -> tuple[dict[str, Any], str]:
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        message = "missing opening frontmatter delimiter"
        raise ValueError(message)
    try:
        end = lines.index("---", 1)
    except ValueError as error:
        message = "missing closing frontmatter delimiter"
        raise ValueError(message) from error

    metadata: dict[str, Any] = {}
    for line in lines[1:end]:
        if not line.strip():
            continue
        if ":" not in line:
            message = f"invalid frontmatter line: {line}"
            raise ValueError(message)
        key, raw = line.split(":", 1)
        key, value = key.strip(), raw.strip()
        # Last-wins would let a block carrying six lines satisfy a rule about
        # five keys, so the repeat is the error rather than the survivor.
        if key in metadata:
            message = f"duplicate frontmatter key: {key}"
            raise ValueError(message)
        metadata[key] = (
            _parse_list(value)
            if key in {"audience", "canonical_for", "requires"}
            else json.loads(value)
            if value.startswith('"')
            else value.strip("'")
        )
    return metadata, "\n".join(lines[end + 1 :])


def _slug(heading: str) -> str:
    heading = heading.strip().lower()
    heading = re.sub(r"[^\w\- ]", "", heading)
    return re.sub(r"\s+", "-", heading)


def _anchors(headings: list[tuple[int, str]]) -> set[str]:
    found: set[str] = set()
    counts: dict[str, int] = {}
    for _level, heading in headings:
        base = _slug(heading)
        seen = counts.get(base, 0)
        counts[base] = seen + 1
        found.add(base if seen == 0 else f"{base}-{seen}")
    return found


def _exact_case(path: Path, root: Path) -> bool:
    try:
        relative = path.resolve().relative_to(root.resolve())
    except ValueError:
        return False
    current = root.resolve()
    for part in relative.parts:
        try:
            if part not in {entry.name for entry in current.iterdir()}:
                return False
        except OSError:
            return False
        current /= part
    return True


def _reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Refuse an object that names the same key twice.

    The default decoder keeps the last of two identical keys, which would let an
    entry carrying seven lines satisfy a rule about six -- the same last-wins
    hole the frontmatter parsers above close.
    """
    mapping: dict[str, Any] = {}
    for key, value in pairs:
        if key in mapping:
            message = f"duplicate key: {key}"
            raise ValueError(message)
        mapping[key] = value
    return mapping


def _load_manifest(manifest: Path, errors: list[str]) -> list[dict[str, Any]]:
    try:
        # JSONDecodeError is a ValueError, so the one clause catches the decoder
        # and the hook alike.
        data = json.loads(
            manifest.read_text(encoding="utf-8"), object_pairs_hook=_reject_duplicates
        )
    except (OSError, ValueError) as error:
        errors.append(f"manifest.yml: cannot read JSON-compatible YAML: {error}")
        return []
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        errors.append("manifest.yml: schema_version must be 1")
        return []
    pages = data.get("pages")
    if not isinstance(pages, list):
        errors.append("manifest.yml: pages must be a list")
        return []

    valid: list[dict[str, Any]] = []
    for index, page in enumerate(pages):
        if not isinstance(page, dict) or set(page) != REQUIRED_FIELDS:
            errors.append(
                f"manifest.yml: page {index} must contain exactly {sorted(REQUIRED_FIELDS)}"
            )
            continue
        invalid = False
        for field in ("title", "kind"):
            if not isinstance(page[field], str) or not page[field].strip():
                errors.append(f"manifest.yml: {page['path']}: {field} must be a nonempty string")
                invalid = True
        for field in ("audience", "canonical_for", "requires"):
            value = page[field]
            if not isinstance(value, list) or any(
                not isinstance(item, str) or not item.strip() for item in value
            ):
                errors.append(
                    f"manifest.yml: {page['path']}: {field} must be a list of nonempty strings"
                )
                invalid = True
        if invalid:
            continue
        valid.append(page)
    return valid


def _check_entry(
    page: dict[str, Any],
    owners: dict[str, str],
    errors: list[str],
    predicates: set[str],
    enabled: set[str],
) -> None:
    relative = page["path"]
    if page["kind"] not in KINDS:
        errors.append(f"manifest.yml: unsupported kind for {relative}: {page['kind']!r}")
    if not page["audience"] or not set(page["audience"]).issubset(AUDIENCES):
        errors.append(f"manifest.yml: {relative} has an empty or unsupported audience")
    if not page["canonical_for"]:
        errors.append(f"manifest.yml: {relative} must own at least one canonical topic")

    for topic in page["canonical_for"]:
        if topic in owners:
            errors.append(
                f"manifest.yml: topic {topic!r} is owned by both {owners[topic]} and {relative}"
            )
        else:
            owners[topic] = relative

    requires = set(page["requires"])
    if unknown := requires - predicates:
        errors.append(f"manifest.yml: {relative} requires unknown predicates {sorted(unknown)}")
    if disabled := requires - enabled - (requires - predicates):
        errors.append(f"manifest.yml: {relative} requires disabled predicates {sorted(disabled)}")


def _check_page(
    relative: str, page: dict[str, Any], text: str, document: _Document, errors: list[str]
) -> None:
    for label, pattern in BAD_CONTENT.items():
        if pattern.search(text):
            errors.append(f"docs/{relative}: contains {label}")
    try:
        metadata, body = _parse_frontmatter(text)
    except ValueError as error:
        errors.append(f"docs/{relative}: {error}")
        return

    if set(metadata) != METADATA_FIELDS:
        errors.append(
            f"docs/{relative}: frontmatter must contain exactly {sorted(METADATA_FIELDS)}"
        )
    errors.extend(
        f"docs/{relative}: frontmatter {field} disagrees with the manifest"
        for field in METADATA_FIELDS & set(metadata)
        if metadata[field] != page[field]
    )

    heading = document.headings[0] if document.headings else None
    if heading is None or heading[0] != 1:
        errors.append(f"docs/{relative}: the first heading must be level one")
    elif heading[1] != page["title"]:
        errors.append(f"docs/{relative}: the level-one heading disagrees with the title")

    words = re.findall(r"\b[\w'-]+\b", re.sub(r"[#*`>|\-]", " ", body))
    if len(words) < MINIMUM_WORDS:
        errors.append(f"docs/{relative}: too short to be substantive")


def _check_links(
    documents: dict[Path, _Document], errors: list[str], project_root: Path
) -> dict[Path, set[Path]]:
    graph: dict[Path, set[Path]] = {path: set() for path in documents}
    cache = dict(documents)
    root, docs = project_root.resolve(), (project_root / "docs").resolve()

    for source, document in documents.items():
        for raw in document.targets:
            target = raw.strip()
            if URL_SCHEME.match(target) or target.startswith("//"):
                continue
            path_text, separator, fragment = target.partition("#")
            resolved = source if not path_text else (source.parent / unquote(path_text)).resolve()
            name = source.relative_to(root)

            try:
                resolved.relative_to(root)
            except ValueError:
                errors.append(f"{name}: link escapes the repository: {raw}")
                continue
            if not resolved.exists() or not _exact_case(resolved, project_root):
                errors.append(f"{name}: missing or case-mismatched link target: {raw}")
                continue
            if separator and resolved.suffix.lower() == ".md":
                if resolved not in cache:
                    text = _read_page(resolved, root, errors)
                    if text is None:
                        continue
                    cache.update(_documents({resolved: text}, errors))
                target_document = cache.get(resolved)
                if target_document and unquote(fragment) not in target_document.anchors:
                    errors.append(f"{name}: missing heading anchor in {raw}")
            if resolved.is_relative_to(docs) and resolved in graph:
                graph[source].add(resolved)
    return graph


def _unreachable(graph: dict[Path, set[Path]], docs: Path) -> list[Path]:
    start = (docs / "README.md").resolve()
    seen: set[Path] = set()
    queue: deque[Path] = deque([start])
    while queue:
        current = queue.popleft()
        if current in seen:
            continue
        seen.add(current)
        queue.extend(graph.get(current, set()) - seen)
    return sorted(set(graph) - seen)


def _read_page(path: Path, root: Path, errors: list[str]) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        errors.append(f"{path.relative_to(root)}: cannot read UTF-8 page: {error}")
        return None


def main() -> int:
    """Report every documentation-contract violation at once."""
    root = _project.root()
    docs = root / "docs"
    predicates, enabled = _project.predicates(root)
    errors: list[str] = []
    pages = _load_manifest(docs / "manifest.yml", errors)

    markdown: dict[Path, str] = {}
    for path in sorted(docs.rglob("*")):
        if path.suffix.lower() not in {".md", ".html", ".htm"}:
            continue
        resolved = path.resolve()
        if path.is_symlink() or not path.is_file():
            errors.append(f"{path.relative_to(root)}: pages must be regular files")
            continue
        text = _read_page(resolved, root, errors)
        if text is not None:
            markdown[resolved] = text

    declared: dict[str, dict[str, Any]] = {}
    owners: dict[str, str] = {}
    for page in pages:
        relative = page["path"]
        if (
            not isinstance(relative, str)
            or relative.startswith("/")
            or ".." in Path(relative).parts
        ):
            errors.append(f"manifest.yml: unsafe page path {relative!r}")
            continue
        if relative in declared:
            errors.append(f"manifest.yml: duplicate page path {relative}")
            continue
        declared[relative] = page
        _check_entry(page, owners, errors, predicates, enabled)

    present = {str(path.relative_to(docs.resolve())) for path in markdown}
    if "README.md" not in present:
        errors.append("docs/README.md: required navigation root is missing")
    errors.extend(
        f"docs/{name}: missing from manifest.yml" for name in sorted(present - set(declared))
    )
    errors.extend(
        f"manifest.yml: declared page does not exist: {name}"
        for name in sorted(set(declared) - present)
    )

    documents = _documents(markdown, errors)
    for relative, page in declared.items():
        path = (docs / relative).resolve()
        document = documents.get(path)
        if document is not None and Path(relative).suffix.lower() == ".md":
            _check_page(relative, page, markdown[path], document, errors)

    graph = _check_links(documents, errors, root)
    errors.extend(
        f"{path.relative_to(root)}: not reachable from docs/README.md"
        for path in _unreachable(graph, docs)
    )

    if errors:
        for error in sorted(set(errors)):
            print(f"docs validation: {error}", file=sys.stderr)
        return 1
    print(f"Validated {len(markdown)} pages and {len(owners)} canonical topics.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
