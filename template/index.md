---
title: index
tags: [index]
date: {{TODAY}}
status: active
---

# {{VAULT_TITLE}}

## Projects

One line per project. Detail lives in each namespace index.

<!-- setup.sh does not touch this list. Add a line when you add a project. -->

## Shared patterns

Stack agnostic lessons that hold in more than one project. When a decision or
a bug looks generalisable, write an atomic page under `patterns/` and link it
here.

## Adding a project

1. Add a `[project:<name>]` section to `config.ini` in your A5N checkout.
2. Run `scripts/setup.sh` again to create the namespace skeleton.
3. Add one line to the projects list above.
