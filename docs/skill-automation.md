# Skill automation

This document used to carry the full model-routing audit for the bespoke
per-task skills that lived in this repository and the scripts tree they were
extracted into. Both moved to the separate `wurk` repo and are installed here
as the generic `wurk:*` skills and `wurk:kit` scripts (ADR-0015, amended by
ADR-0016, superseded by ADR-0017). The generic skills carry their own
`model:` frontmatter and make their own internal delegation-to-a-cheaper-model
choices now; no generic skill cites this document for that, and it no longer
needs to restate their contracts.

What is still specific to this project - which lifecycle stage runs on which
model, and why - is documented once, in `docs/workflow.md`'s Model roles
section. Read that instead of this file for anything about stage-to-model
routing today; it is the current, living statement, and duplicating it here
would just be a second place for the two to drift apart.

The full per-skill classification this document used to carry - the
scriptable/cheaper-model/session-model split across ~189 steps, the
skill-to-script mapping, and the delegation-candidate reasoning - is
preserved as a dated snapshot in
`docs/research/260806-st-hzf-skill-mechanics-scripts.md`. It describes the
tree as it stood on 2026-08-06, before the move this document now records;
read it as history, not as a description of how this repo works today.
