# Task guidance

Fixture data for the scenario suite. Each task rule declares the triggers that route to it,
so selection is by DECLARED trigger and an exact source reference rather than by guessing
from the prose. A task rule with no trigger is refused at generation time, because a routed
rule nothing can route to is a rule that silently never applies.

<!-- jesse-rule: id=start-of-day scope=task section="Task Guidance" triggers="greeting, good morning, start of day, new session" -->
- **Start of day.** Any session opening greeting starts the morning routine: read the daily
  list first because the owner may have edited it, then rebuild it. Each item carries the
  topic file it belongs to and, first in the line, the note to open on tap.
<!-- /jesse-rule -->

<!-- jesse-rule: id=process-updates scope=task section="Task Guidance" triggers="process updates" -->
- **Process updates is a different job from start of day, and must not be confused with it.**
  Close the checked items at their source, refill the bottom of the list only if it has run
  short, and never rebuild the daily list. It is not a morning routine and it does not run
  one.
<!-- /jesse-rule -->

<!-- jesse-rule: id=meeting-agendas scope=task section="Task Guidance" triggers="meeting, agenda, call" -->
- **Meeting agendas.** Keep an agenda fresh until the meeting starts and show the delta when
  updating it rather than replacing it silently.
<!-- /jesse-rule -->

<!-- jesse-rule: id=entity-journals scope=task section="Task Guidance" triggers="person, project, journal, people" -->
- **Entity journals.** Read the journal before engaging with any person or project that keeps
  one, and record a meaningful interaction in it afterwards.
<!-- /jesse-rule -->

<!-- jesse-rule: id=drafting-style scope=task section="Task Guidance" triggers="draft, write, report, prose" -->
- **Drafting.** Read the writing voice notes before any prose meant for another person, and
  run the draft lint over the landed copy rather than over the version in the chat.
<!-- /jesse-rule -->

<!-- jesse-rule: id=codex-sandbox scope=adapter section="This Harness" adapters="codex" -->
- A refusal from the sandbox is a boundary, not an error to route around. Report what you
  could not do and stop; do not look for a second path to the same write.
<!-- /jesse-rule -->

<!-- jesse-rule: id=claude-code-allowlist scope=adapter section="This Harness" adapters="claude-code" -->
- A tool that is not in this turn's allowlist does not exist for this turn. Say that you did
  not have it rather than describing having used it.
<!-- /jesse-rule -->
