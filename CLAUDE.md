# glide

## What this is
{{WHAT_THIS_IS}}

## Stack
{{STACK}}

## Commands
{{COMMANDS}}

## Milestones — status and which model to use
Product scope, non-goals, and open questions live in `docs/prd.md`.

| # | Scope | Status | Model / effort |
|---|---|---|---|
{{MILESTONES}}

Default is your strongest model + high effort. Raise to maximum effort only for
adversarial or security work; drop to a cheap model + medium for UI boilerplate.

**State the model and effort at the start of every milestone, before working.**

## Conventions
- Ask before adding a dependency.
- Never commit secrets. Credentials go in `.env`, which is gitignored and denied to the agent.

## House rules
- Show a plan before multi-file changes.
- **Before adding a feature to working code, run the tests FIRST.** A green
  baseline turns "did I break this?" from an hour of debugging into a fact. A
  red one means you found someone else's break in sixty seconds.
- **Before committing a feature, run `git diff --stat` against the last
  `ship(` commit and justify every file.** A file you cannot explain in a few
  words is scope creep with a diff to prove it. If the new code's only callers
  are its own file and its own test, it is parked beside the project rather
  than wired into it — connect it or delete it.
- **If the diff contradicts a sentence in a doc, that sentence is part of the
  diff.** Deferred doc updates never happen, and a confidently wrong CLAUDE.md
  misleads worse than a missing one.
- After editing, run the test command and report the real result, not the expected one.
- If you are unsure, say so instead of guessing.

<!--
Keep this file under ~100 lines. Add a line only after correcting the same
thing twice. This file is the project's source of truth and is committed to git.
-->
