# Threat model — glide

Re-read at the start of each milestone; a threat model
that is never revisited is decoration.

## What we protect, and from whom

| Asset | Adversary | Why it matters |
|---|---|---|
{{ASSETS}}

Name the adversary concretely. "A hacker" is useless. "A player who has
decompiled the client", "a logged-in user changing an id in a request", "an
employee about to resign" each lead somewhere.

## Current posture

{{POSTURE}}

Be honest about what is not built yet. "No auth" written down is safe;
"no auth" forgotten is a breach.

## Rules that must hold

{{RULES}}

Each rule should be enforceable by something other than memory — a test, a
type, a lint, a CI step. A rule that relies on remembering will be broken.

## Accepted risks

{{ACCEPTED}}

Things knowingly not fixed, and why. This is the section that stops a future
reader from assuming an oversight.

## Practice

- `/ship` before calling any milestone done — it runs tests, a code review,
  and a scoped security pass.
- CI runs the checks on every push.
- When a security-relevant assumption changes, edit this file in the same commit.
