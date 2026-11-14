---
title: "Documentation contract"
kind: "reference"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["documentation_contract"]
requires: []
---

# Documentation contract

`just docs-check` runs the copied documentation validator. `just check` includes it under the worktree snapshot guarantee: a check may report problems but may not change tracked or untracked, unignored files. The source and permitted adaptations are recorded in [Decision 0004](../decisions/0004-gate-checkers.md).

## Manifest and metadata

`docs/manifest.yml` is JSON-compatible YAML with `schema_version` set to `1` and a `pages` array. Every Markdown or HTML page under `docs/` appears exactly once. Paths are relative to that directory. Specification files, images, root maintainer documents, and bootstrap evidence are not handbook pages.

Every entry has exactly these six fields:

| Field | Contract |
| --- | --- |
| `path` | A relative page path without parent traversal; the file must exist. |
| `title` | A nonempty string naming the page. |
| `kind` | One of `project`, `tutorial`, `how-to`, `explanation`, `reference`, `operations`, or `decision`. |
| `audience` | A nonempty list drawn from `user`, `contributor`, `maintainer`, `operator`, and `agent`. |
| `canonical_for` | A nonempty list of nonempty topic strings owned exclusively by this page. |
| `requires` | A list of nonempty strings naming enabled feature predicates declared in `[docs] predicates` in `checks.toml`. |

Markdown frontmatter repeats exactly the five fields other than `path`, using scalar strings and inline lists. Duplicate keys are errors. Its first heading is level one and matches the title. Body content contains at least forty words and no unfinished annotations, template syntax, or placeholder prose. An introductory page explains current scope and future ownership instead of pretending an unimplemented feature exists.

`requires` is not a list of related pages or decision dependencies. Those are ordinary prose links. Knarr currently declares no feature predicates, so every page uses an empty list. Only the TOML boolean `true` enables a predicate.

## Navigation and HTML

Every page must be reachable through links from [the documentation index](../README.md). Rendered Markdown links and HTML anchor links participate in this graph. Links and headings inside code examples or comments do not count; reference-style links and explicit HTML anchors do. The navigation root must exist, even if the manifest has no pages. Relative local targets must exist with the correct case and stay inside the repository. Scheme-qualified and protocol-relative URLs are left to the link audit rather than interpreted as filesystem paths. Markdown heading fragments are checked by the validator. Pages must be regular UTF-8 files, not symlinks; unreadable files produce diagnostics.

HTML pages use manifest metadata alone. They do not need Markdown frontmatter, Markdown headings, a Markdown word count, or Markdown content-marker checks. They still require registration, unique canonical topics, valid predicates, and reachability. This exception lets the [overview explainer](../overview-explainer.html) remain a standalone HTML document. Lychee checks HTML links, resources, and fragments.

## Parser runtime

The Python checker uses only standard-library imports. For Markdown structure it invokes `render_markdown.mjs` with the Node runtime and `markdown-it` parser already shipped in the pinned markdownlint-cli2 environment. Both are loaded from this checkout's `.nix/tools`, never an unrelated global npm installation. Initialization installs them through the existing lockfile; validation neither installs packages nor executes document content. This keeps navigation checks aligned with Markdown structure without maintaining a second regex-based parser.

## Gate and audit

`just lint` runs markdownlint, typos, and offline lychee through local hooks. Lychee covers Markdown and HTML, including local fragments. The gate never fetches external links. `just links-audit` checks links online over the repository's Markdown and HTML files, including bootstrap documentation; generated tool and build directories are outside its inputs.

The separate audit workflow runs weekly and on manual dispatch, with no required status-check role. External failures belong there because remote availability can change independently of a commit. Fix a reported link at its source; do not add broad exclusions simply to make a check green.
