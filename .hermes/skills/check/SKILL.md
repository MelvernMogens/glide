---
name: check
description: "Run project tests in an isolated subagent, report only failures."
---

Run the project's checks. $ARGUMENTS

If no command was given, read `CLAUDE.md` for the test command. If it is still
TBD, look for a build/test script in the project's manifest file. If there is
nothing to run, say so and stop — do not invent a command.

Run the command inside a fresh `delegate_task` subagent so verbose output stays
out of the main conversation.

Report in this format and nothing else:

PASS - <command you ran>

or

FAIL - <command you ran>
<failing test or error>: <one-line message>
  <file:line>

Do not paste full stack traces, passing tests, or build progress. Do not attempt
a fix. Reporting accurately is the entire job.
