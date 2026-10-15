"""Documentation contract through the entrypoint, using real temporary Git trees."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from conftest import run_checker

PROSE = (
    "This page explains the documentation contract for contributors maintaining the project. "
    "Every page declares its audience and owns a canonical topic so readers can find the "
    "authoritative explanation. The gate checks these declarations and local links without "
    "changing the repository or requiring a network connection."
)


def entry(path: str, title: str, topic: str) -> dict[str, object]:
    return {
        "path": path,
        "title": title,
        "kind": "reference",
        "audience": ["contributor", "agent"],
        "canonical_for": [topic],
        "requires": [],
    }


def write_page(repository: Path, page: dict[str, object], body: str = PROSE) -> None:
    path = repository / "docs" / str(page["path"])
    path.parent.mkdir(parents=True, exist_ok=True)
    metadata = "\n".join(f"{k}: {json.dumps(v)}" for k, v in page.items() if k != "path")
    path.write_text(f"---\n{metadata}\n---\n\n# {page['title']}\n\n{body}\n")


def manifest(repository: Path, pages: list[dict[str, object]]) -> None:
    (repository / "docs" / "manifest.yml").write_text(
        json.dumps({"schema_version": 1, "pages": pages})
    )


@pytest.fixture
def handbook(repository: Path) -> Path:
    (repository / "checks.toml").write_text("[docs]\npredicates = {}\n")
    page = entry("README.md", "Documentation", "documentation")
    write_page(repository, page)
    manifest(repository, [page])
    return repository


def check(repository: Path, *, cli: bool = False) -> subprocess.CompletedProcess[str]:
    before = {
        p.relative_to(repository): p.read_bytes() for p in repository.rglob("*") if p.is_file()
    }
    result = run_checker("validate_docs", repository, cli=cli)
    after = {
        p.relative_to(repository): p.read_bytes() for p in repository.rglob("*") if p.is_file()
    }
    assert after == before, "validation must not write"
    return result


def test_valid_markdown_tree_passes(handbook: Path) -> None:
    result = check(handbook)
    assert result.returncode == 0, result.stderr
    assert "Validated 1 pages" in result.stdout


def test_html_uses_manifest_metadata_and_participates_in_reachability(handbook: Path) -> None:
    index = entry("README.md", "Documentation", "documentation")
    html = entry("explainer.html", "Explainer", "explainer")
    detail = entry("detail.md", "Details", "details")
    write_page(handbook, index, PROSE + "\n\n[Explainer](explainer.html)")
    write_page(handbook, detail)
    (handbook / "docs/explainer.html").write_text(
        '<!doctype html><title>Explainer</title><a href="detail.md">Details</a>'
    )
    manifest(handbook, [index, html, detail])
    result = check(handbook)
    assert result.returncode == 0, result.stderr
    assert "Validated 3 pages" in result.stdout


@pytest.mark.parametrize("suffix", ["md", "html"])
def test_unregistered_page_is_refused(handbook: Path, suffix: str) -> None:
    (handbook / f"docs/extra.{suffix}").write_text("Unregistered page")
    result = check(handbook)
    assert result.returncode == 1
    assert f"extra.{suffix}: missing from manifest.yml" in result.stderr


@pytest.mark.parametrize("suffix", ["md", "html"])
def test_unreachable_page_is_refused(handbook: Path, suffix: str) -> None:
    index = entry("README.md", "Documentation", "documentation")
    extra = entry(f"extra.{suffix}", "Extra", "extra")
    if suffix == "md":
        write_page(handbook, extra)
    else:
        (handbook / f"docs/extra.{suffix}").write_text("<!doctype html><title>Extra</title>")
    manifest(handbook, [index, extra])
    result = check(handbook)
    assert result.returncode == 1
    assert f"extra.{suffix}: not reachable" in result.stderr


@pytest.mark.parametrize(
    ("change", "diagnostic"),
    [
        ({"title": "Changed"}, "frontmatter title disagrees"),
        ({"kind": "unknown"}, "unsupported kind"),
        ({"audience": []}, "empty or unsupported audience"),
        ({"canonical_for": []}, "must own at least one canonical topic"),
        ({"requires": ["future"]}, "requires unknown predicates"),
        ({"path": "../escape.md"}, "unsafe page path"),
        ({"path": "/absolute.md"}, "unsafe page path"),
        ({"path": "missing.md"}, "declared page does not exist"),
    ],
)
def test_invalid_manifest_entry_is_refused(
    handbook: Path, change: dict[str, object], diagnostic: str
) -> None:
    page = entry("README.md", "Documentation", "documentation")
    manifest(handbook, [{**page, **change}])
    result = check(handbook)
    assert result.returncode == 1
    assert diagnostic in result.stderr


@pytest.mark.parametrize("enabled", ["false", '"true"'])
def test_only_enabled_boolean_predicate_is_accepted(handbook: Path, enabled: str) -> None:
    page = entry("README.md", "Documentation", "documentation")
    page["requires"] = ["future"]
    write_page(handbook, page)
    manifest(handbook, [page])
    config = handbook / "checks.toml"
    config.write_text(f"[docs]\npredicates = {{ future = {enabled} }}\n")
    result = check(handbook)
    assert result.returncode == 1
    assert "requires disabled predicates" in result.stderr
    config.write_text("[docs]\npredicates = { future = true }\n")
    result = check(handbook)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    ("extra_path", "extra_topic", "diagnostic"),
    [
        ("README.md", "extra", "duplicate page path"),
        ("extra.md", "documentation", "is owned by both"),
    ],
)
def test_duplicate_registration_is_refused(
    handbook: Path, extra_path: str, extra_topic: str, diagnostic: str
) -> None:
    index = entry("README.md", "Documentation", "documentation")
    extra = entry(extra_path, "Extra", extra_topic)
    manifest(handbook, [index, extra])
    result = check(handbook)
    assert result.returncode == 1
    assert diagnostic in result.stderr


@pytest.mark.parametrize(
    ("body", "diagnostic"),
    [
        ("Brief.", "too short"),
        (PROSE + "\nTODO: finish", "unfinished marker"),
        (PROSE + " {{ template }}", "unresolved template syntax"),
        (PROSE + " lorem ipsum", "placeholder prose"),
        (PROSE + " [Missing](absent.md)", "missing or case-mismatched link target"),
        (PROSE + " [Anchor](README.md#absent)", "missing heading anchor"),
        (PROSE + " [Escape](../../outside.md)", "link escapes the repository"),
    ],
)
def test_invalid_markdown_is_refused(handbook: Path, body: str, diagnostic: str) -> None:
    write_page(handbook, entry("README.md", "Documentation", "documentation"), body)
    result = check(handbook)
    assert result.returncode == 1
    assert diagnostic in result.stderr


@pytest.mark.parametrize(
    ("old", "new", "diagnostic"),
    [
        ("---\n", "", "missing opening frontmatter delimiter"),
        ("# Documentation", "## Documentation", "first heading must be level one"),
        ('kind: "reference"', 'kind: "reference"\nkind: "reference"', "duplicate frontmatter key"),
    ],
)
def test_invalid_page_structure_is_refused(
    handbook: Path, old: str, new: str, diagnostic: str
) -> None:
    page = handbook / "docs/README.md"
    page.write_text(page.read_text().replace(old, new, 1))
    result = check(handbook)
    assert result.returncode == 1
    assert diagnostic in result.stderr


def test_duplicate_json_keys_are_refused(handbook: Path) -> None:
    path = handbook / "docs/manifest.yml"
    path.write_text(
        path.read_text().replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1')
    )
    result = check(handbook)
    assert result.returncode == 1
    assert "duplicate key: schema_version" in result.stderr


def test_missing_docs_configuration_is_refused(handbook: Path) -> None:
    (handbook / "checks.toml").write_text("")
    result = check(handbook)
    assert result.returncode == 2
    assert "has no [docs] table" in result.stderr


def test_symlink_page_is_refused(handbook: Path) -> None:
    (handbook / "docs/alias.md").symlink_to("README.md")
    result = check(handbook)
    assert result.returncode == 1
    assert "pages must be regular files" in result.stderr


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("title", ""),
        ("title", None),
        ("kind", ["reference"]),
        ("audience", [["agent"]]),
        ("canonical_for", "topic"),
        ("canonical_for", None),
        ("canonical_for", [""]),
        ("canonical_for", [1]),
        ("requires", ""),
        ("requires", {}),
    ],
)
def test_html_manifest_fields_have_strict_types(handbook: Path, field: str, value: object) -> None:
    index = entry("README.md", "Documentation", "documentation")
    html = entry("explainer.html", "Explainer", "explainer")
    html[field] = value
    write_page(handbook, index, PROSE + "\n\n[Explainer](explainer.html)")
    (handbook / "docs/explainer.html").write_text("<!doctype html><title>Explainer</title>")
    manifest(handbook, [index, html])
    result = check(handbook)
    assert result.returncode == 1
    assert f"manifest.yml: explainer.html: {field}" in result.stderr
    assert "Traceback" not in result.stderr


@pytest.mark.parametrize(
    "example",
    [
        "<!-- [Details](detail.md) -->",
        "`[Details](detail.md)`",
        "```markdown\n[Details](detail.md)\n```",
        "~~~markdown\n[Details](detail.md)\n~~~",
        "    [Details](detail.md)",
    ],
)
def test_examples_and_comments_do_not_make_pages_reachable(handbook: Path, example: str) -> None:
    index = entry("README.md", "Documentation", "documentation")
    detail = entry("detail.md", "Details", "details")
    write_page(handbook, index, PROSE + "\n\n" + example)
    write_page(handbook, detail)
    manifest(handbook, [index, detail])
    result = check(handbook)
    assert result.returncode == 1
    assert "detail.md: not reachable" in result.stderr


@pytest.mark.parametrize(
    ("link", "target"),
    [
        ("[Details][detail]\n\n[detail]: detail.md", "detail.md"),
        ("[Details][]\n\n[Details]: detail.md", "detail.md"),
        ("[Details]\n\n[Details]: detail.md", "detail.md"),
        ("[Details](<a b.md>)", "a b.md"),
        ("[Details](detail(one).md)", "detail(one).md"),
        ('<a href="detail.md">Details</a>', "detail.md"),
    ],
)
def test_rendered_markdown_links_make_pages_reachable(
    handbook: Path, link: str, target: str
) -> None:
    index = entry("README.md", "Documentation", "documentation")
    detail = entry(target, "Details", "details")
    write_page(handbook, index, PROSE + "\n\n" + link)
    write_page(handbook, detail)
    manifest(handbook, [index, detail])
    result = check(handbook)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    ("body", "fragment", "passes"),
    [
        ("```sh\n# Ghost\n```", "ghost", False),
        ("<!--\n# Ghost\n-->", "ghost", False),
        ("```sh\n# Heading\n```\n\n## Heading", "heading-1", False),
        ("## Heading\n\n## Heading", "heading-1", True),
        ("## See [RFC](README.md)", "see-rfc", True),
        ("## A `code` example", "a-code-example", True),
        ('<a id="custom"></a>', "custom", True),
        ('<a name="legacy"></a>', "legacy", True),
    ],
)
def test_fragments_follow_rendered_headings_and_explicit_anchors(
    handbook: Path, body: str, fragment: str, *, passes: bool
) -> None:
    page = entry("README.md", "Documentation", "documentation")
    write_page(handbook, page, PROSE + f"\n\n{body}\n\n[Anchor](#{fragment})")
    result = check(handbook)
    assert result.returncode == (0 if passes else 1), result.stderr
    if not passes:
        assert "missing heading anchor" in result.stderr


@pytest.mark.parametrize(
    "target",
    ["HTTPS://example.invalid/x", "//example.invalid/x", "tel:+1234", "ftp://example.invalid/x"],
)
def test_nonlocal_html_links_are_not_filesystem_paths(handbook: Path, target: str) -> None:
    index = entry("README.md", "Documentation", "documentation")
    html = entry("explainer.htm", "Explainer", "explainer")
    write_page(handbook, index, PROSE + "\n\n[Explainer](explainer.htm)")
    (handbook / "docs/explainer.htm").write_text(f'<a href="{target}">External</a>')
    manifest(handbook, [index, html])
    result = check(handbook)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("target", ["docs/bad.md", "docs/bad.html", "outside.md"])
def test_non_utf8_pages_report_a_diagnostic(handbook: Path, target: str) -> None:
    index = entry("README.md", "Documentation", "documentation")
    write_page(handbook, index, PROSE + f"\n\n[Bad](../{target}#heading)")
    (handbook / target).write_bytes(b"# Heading\n\nLatin-1: \xe9\n")
    pages = [index]
    if target.startswith("docs/"):
        pages.append(entry(target.removeprefix("docs/"), "Bad", "bad"))
    manifest(handbook, pages)
    result = check(handbook)
    assert result.returncode == 1
    assert f"{target}: cannot read UTF-8 page" in result.stderr
    assert "Traceback" not in result.stderr


@pytest.mark.parametrize("suffix", ["html", "htm"])
@pytest.mark.parametrize(
    ("target", "diagnostic"),
    [
        ("missing.md", "missing or case-mismatched link target"),
        ("readme.md", "missing or case-mismatched link target"),
        ("../../outside.md", "link escapes the repository"),
        ("README.md#absent", "missing heading anchor"),
    ],
)
def test_html_outgoing_links_are_validated(
    handbook: Path, suffix: str, target: str, diagnostic: str
) -> None:
    index = entry("README.md", "Documentation", "documentation")
    html = entry(f"explainer.{suffix}", "Explainer", "explainer")
    write_page(handbook, index, PROSE + f"\n\n[Explainer](explainer.{suffix})")
    (handbook / f"docs/explainer.{suffix}").write_text(f'<a href="{target}">Link</a>')
    manifest(handbook, [index, html])
    result = check(handbook)
    assert result.returncode == 1
    assert diagnostic in result.stderr


def test_an_empty_handbook_cannot_pass_without_the_navigation_root(handbook: Path) -> None:
    (handbook / "docs/README.md").unlink()
    manifest(handbook, [])
    result = check(handbook)
    assert result.returncode == 1
    assert "docs/README.md: required navigation root is missing" in result.stderr


@pytest.mark.parametrize("broken", [False, True])
def test_cli_contract(handbook: Path, broken: bool) -> None:
    if broken:
        (handbook / "docs/extra.md").write_text("Unregistered page")
    result = check(handbook, cli=True)
    assert result.returncode == int(broken), result.stderr
    assert (
        "missing from manifest" in result.stderr
        if broken
        else "Validated 1 pages" in result.stdout
    )
