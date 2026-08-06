---
title: log
tags: [log]
date: {{TODAY}}
status: active
---

# Vault level log

Per project ingest, query and lint entries live in `<project>/log.md`. This
file is only for events that affect the whole vault: a new project, a schema
change, an update to the root `index.md` or to `patterns/`.

Format: `## [YYYY-MM-DD] <setup|schema|pattern> | <detail>`

## [{{TODAY}}] setup | vault created by A5N setup
