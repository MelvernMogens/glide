---
name: hard
description: "Escalate one stuck problem to a fresh context for re-derivation."
---

Problem: $ARGUMENTS

Do not solve this inline. Hand it to a fresh `delegate_task` subagent with
these rules:

1. Re-derive the problem from the actual files. Do not trust the framing above —
   it came from the attempt that failed.
2. Verify with a real command (test, build, run) before claiming success.
3. Change as little as possible.

The subagent must end its reply with exactly one of these two lines:

SOLVED: <one sentence> - verified by: <the exact command it ran>
NOT SOLVED: <the single specific thing blocking it>

Never guess to fill the SOLVED line. "NOT SOLVED" with a precise blocker is a
correct and useful answer. A plausible-looking wrong answer is the exact failure
mode this escalation exists to prevent.
