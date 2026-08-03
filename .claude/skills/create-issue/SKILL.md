---
name: create-issue
description: Create beads (bd) issues with type, priority, labels, and dependency links
argument-hint: ["issue title or description"]
---

# Create Issue (beads)

Create a new issue in the beads (`bd`) tracker. All task tracking in this project
is beads - no GitHub issues, no markdown TODO lists (see docs/workflow.md and
ADR-0007).

## Gather the details

From `$ARGUMENTS` if provided; otherwise ask the user for:

- **Title** - short, imperative (e.g. "Implement compute_exit_set for parallel states")
- **Description** - context, acceptance criteria, relevant file paths or spec sections
- **Type** - task, bug, feature, epic, or chore
- **Priority** - 0 (urgent) through 3 (low); default 2 if the user has no preference
- **Related work** (optional) - existing issue IDs this blocks, depends on, or was
  discovered from

Infer type and priority from the description when they are obvious; only ask about
what is genuinely ambiguous. Do not interrogate the user field by field.

## Create the issue

Full form:

```bash
bd create "Title here" --type task --priority 2 --description "Longer context..."
```

Quick capture (when the user just wants it recorded fast, e.g. mid-task discovered
work):

```bash
bd q "Title here"
```

Check `bd create --help` if unsure of exact flag names in the installed version.

## Link dependencies

When the user names related work, link it:

```bash
bd link <new-id> --depends-on <other-id>
bd link <new-id> --discovered-from <other-id>
```

Use `discovered-from` for work found mid-task; use dependency links so `bd ready`
reflects the real build order (parser before interpreter features, etc.). Epics
mirror the roadmap phases - if the new issue belongs to an epic, link it as a child.

## Apply labels

- Add at least one **`area:`** label to every issue that will change files in this
  repo - `area:interpreter`, `area:parser`, `area:datamodel`, `area:corpus`,
  `area:test-harness`, `area:skills`, `area:docs`, `area:build`. The vocabulary
  and the paths each covers are in
  [docs/workflow.md](../../../docs/workflow.md#area-labels). This is not a
  topical tag: it is what lets a batch picker tell whether two issues collide,
  so label by the paths in the acceptance criteria, not by subject matter, and
  use `area:build` for anything touching `mix.exs`, `mix.lock`, `.quality.exs`,
  or `.credo.exs` - those beads batch with nothing.
- Add topical labels the user mentions (e.g. `tooling`, `workflow`, `quality`).
- Add the **`upstream`** label when the issue is an upstream candidate for
  predicator, uxid, or ex_quality (a seam or fix that belongs in those repos), so
  it can be swept into their trackers later. An `upstream` issue changes no files
  here, so it takes no `area:` label.

```bash
bd update <id> --add-label area:parser --add-label upstream
```

## Report back

Print the created issue ID and title, e.g.:

```
Created st2-b57: Implement compute_exit_set for parallel states (task, p2)
Linked: depends-on st2-a42; labeled: interpreter
```

Do not commit, push, or sync the beads database unless explicitly asked.
