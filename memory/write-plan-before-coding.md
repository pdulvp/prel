---
name: write-plan-before-coding
description: Before coding in a repository that keeps docs/plans/, write the intended steps to docs/plans/plan.md, keep it updated, mark it complete in its header when done, sum it up in sumup.md, and archive it alongside as a dated file.
metadata:
  type: feedback
---

Shared memory: this file lives in `/mnt/Data/Works/prel/memory/` and is linked
into each project by `prel memory register` — edits here reach every repository
it is registered for.

Before starting to code, write down what I am about to do in the repo, in
`docs/plans/plan.md`, and keep it updated as steps are done. That path is
gitignored — it is a session draft, not history — and lives in the repo rather
than the scratchpad so it survives a reboot as well as a crash (the scratchpad
is on tmpfs).

Start the file with a status header, and change `status` to `complete` as soon as
the last step is done — in the same response that finishes the work, not later:

```
---
status: in-progress | complete
updated: YYYY-MM-DD HH:MM
---
```

In that same response, write the plan's sum-up to `docs/plans/sumup.md`, in the
format of prel's `plan-summary` skill. The prel hooks turn it into one GitHub
issue at the next commit — covering every `complete` plan that carries no
`issue:` field yet — put `#<n>` in front of the commit subject, stamp the plans
and delete `sumup.md`. `prel issue-from-plans status` says what the next commit
would file.

When the plan reaches `complete`, and whenever an existing plan is about to be
overwritten by a new one, archive it in the repo first:

    docs/plans/AAAA-MM-JJ-HHMM-slug.md

timestamp from the header's `updated` field, slug from the plan's title, then
delete `plan.md` so only live work sits under that name. An in-progress plan
being displaced gets archived as it stands — never silently overwritten.
Archived files are read-only history.

The whole folder is gitignored, a `docs/plans/README.md` stating the convention
excepted (`docs/plans/*` plus `!docs/plans/README.md`) — add those lines if the
repository lacks them. The history of the work lives in the GitHub issues, not
in those files.

**Why:** the user reports sessions crash often; a written plan lets the next
session pick the work up instead of re-deriving it. The explicit status is what
tells that next session whether the plan is live work to resume or a finished
job to leave alone — `[x]` on every step is ambiguous, since a plan can be
abandoned mid-way with its last touched step checked. The sum-up is written by
the session that did the work because it is the one holding the context, and
costs nothing there.

**How to apply:** first tool call of a coding task writes/updates the plan file —
status header, goal, the file-by-file steps, and which ones are already done.
A plan found with `status: complete` is history: archive it, then start a fresh
plan rather than appending to it. Starting a new plan is also the moment to
catch up on a sum-up a crashed session skipped. Not needed for read-only
questions. See [[resume-from-plan-file]].
