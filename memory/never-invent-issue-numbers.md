---
name: never-invent-issue-numbers
description: Never type an issue number into a commit subject or a plan; the `#N` prefix exists only once `gh issue create` has answered, and is written by the prel hooks or `prel attach-issue` alone.
metadata:
  type: feedback
---

Shared memory: this file lives in `/mnt/Data/Works/prel/memory/` and is linked
into each project by `prel memory register` — edits here reach every repository
it is registered for.

An issue identifier exists only once GitHub has created the issue. The `#N` in
front of a commit subject is written by the prel hooks (`issue-from-plans` at
commit time) or by `prel attach-issue` (after the fact), and both take the
number from the URL `gh issue create` answers with — never from a counter,
never from memory, never typed by hand.

So, when committing or writing a plan:

- never start a commit message with `#<n>`; if a draft message carries one,
  delete it before committing;
- never write an `issue:` field into a plan by hand — the post-commit hook
  stamps it from the issue it actually filed;
- if `gh` is missing, unauthenticated or its API call fails, the hooks commit
  without a number and say so on stderr: leave the commit unnumbered and report
  the failure, do not invent a number to keep the sequence going;
- a subject that already starts with `#N` is left alone by the hooks on the
  assumption the issue exists — one hand-typed number makes every later commit
  silently skip filing. To file issues for old commits, strip the hand-typed
  prefixes first, then run `prel attach-issue`.

**Why:** a hand-typed `#N` with no issue behind it is a dangling reference. The
hooks then treat the commit as already attached and file nothing, and plans
get stamped with a number GitHub will never resolve. This is how pdcartes-tarot
ended up with commits #4–#19 and only issues #1–#3 on GitHub.
