---
name: resume-from-plan-file
description: On "continue where you left off" in a repository that keeps docs/plans/, first read the most recently modified plan there and resume from it if its status is not complete.
metadata:
  type: feedback
---

Shared memory: this file lives in `/mnt/Data/Works/prel/memory/` and is linked
into each project by `prel memory register` — edits here reach every repository
it is registered for.

When the user opens a session with "continue", "reprends", "continue what you
were doing", or anything else pointing at unfinished earlier work, the first
tool call finds the most recently modified plan and reads it:

    ls -t docs/plans/*.md | grep -vE 'README|sumup' | head -1

Going by mtime rather than a fixed name means the newest thing in that folder
is the thread, whether that is the live `plan.md` or, once it has been
archived, the latest dated file. Then:

- It is `plan.md`, `status: in-progress` (or no status header): that plan is
  this session's context. Restate the goal and the first unchecked step in a
  line or two so the user can correct me, then carry on from there — do not
  re-derive the plan or redo checked steps without first confirming they
  really landed.
- It is `plan.md`, `status: complete`: a crash caught it before it was
  archived. Archive it per [[write-plan-before-coding]], say the work was
  already finished, and ask what to pick up.
- It is a dated archive: nothing is pending, which is the normal state. Name
  it and say what it covered, then ask whether they mean a follow-up to that
  or something else — do not reopen an archive in place.
- The folder has no plan at all: say there is no saved plan and ask what to
  pick up.

A `sumup.md` left in the folder is not a plan: it is a finished batch waiting
for the commit that files it as a GitHub issue, per
[[write-plan-before-coding]].

**Why:** the user reports sessions crash often, and only `MEMORY.md` loads
automatically — the plan is written for exactly this moment, but nothing reads
it on its own, so a resumed session would otherwise start blind and re-derive
work already done.

**How to apply:** read before planning, before searching the repo, before
touching any file. Only on a resume-shaped request — a fresh task starts a
fresh plan per [[write-plan-before-coding]], and read-only questions need
neither.
