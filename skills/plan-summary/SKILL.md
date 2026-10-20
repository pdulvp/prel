---
name: plan-summary
description: The standard format of docs/plans/sumup.md, the hand-off between a finished work plan and the GitHub issue prel files on the next commit. Use it when marking a plan complete, when archiving one, when starting a new plan, or whenever writing or refreshing docs/plans/sumup.md.
---

# Summing a completed plan up

In a repository that keeps work plans under `docs/plans/` and has the prel
hooks registered, `docs/plans/sumup.md` is what turns finished plans into
history. On the next commit, `prel issue-from-plans` files every plan marked
`status: complete` and not yet carrying an `issue:` field as **one** GitHub
issue, and puts its number in front of the commit subject:

    #12 Paquetage Windows: zip avec les DLL de Qt

`sumup.md` supplies the wording and is the trigger: without it nothing is
filed. The plans themselves are gitignored, so that issue is all that remains
of them — write the sum-up for someone reading the repository's issues in a
year, not for the session that just did the work.

## When to write it

- **In the same response that sets `status: complete`** on a plan, before
  archiving it. This is the moment that matters: the work is done, the context
  is loaded, and the next commit is usually the one that files it.
- **When starting a new plan**, as a catch-up: if any completed plan has no
  `issue:` field and `sumup.md` does not already cover it, add it now — a
  crashed session may have skipped the step above.

Never write it for an in-progress plan, and never delete it by hand: the
`post-commit` hook deletes it once a commit carries the issue, and stamps
`issue: <n>` into each plan it filed.

## Format

```markdown
# Paquetage Windows: zip avec les DLL de Qt

- cible cmake `zip`, pendant de `deb`, produisant une archive horodatée
- fermeture des dépendances DLL vérifiée à l'objdump (Qt, greffons, runtime mingw)
- `QIcon::fromTheme` laissé de côté: les boutons portent leur mot
```

**One H1, first line, 70 characters at most.** It is both the issue title and
the commit subject. A noun phrase or an imperative, no trailing period, no
issue number — prel adds that. No `Plan —` prefix, no date: the plan files
carry those.

**Two to five bullets under it.** They become the commit body and the issue's
lead, above the full text of each plan. One outcome per bullet, the
user-visible ones first, then the ones that only a maintainer cares about.
Name identifiers in backticks. A decision taken and its reason is worth a
bullet; a step that merely happened is not.

**Write it in the language of the repository's plans and commits**, not in the
language of the conversation.

## When it covers several plans

`sumup.md` is cumulative — one issue per batch, not per plan. Adding a second
plan to it means rewriting the H1 so it covers the whole batch, not appending
to it:

```markdown
# Paquetage Windows et équilibrage des rivaux

- zip Windows avec les DLL de Qt, les greffons et le runtime mingw
- huit compétences par rival, XP rééquilibrée sur la courbe de progression
```

If the two plans have nothing in common, the honest title is the broader one
(`Paquetage Windows et corrections diverses`) — or commit the first batch
before starting the second, which gives each its own issue.

## Checking

    prel issue-from-plans status     # what the next commit would file
    prel issue-from-plans dry-run    # the issue and the commit message in full

A title longer than 70 characters, a missing H1, a missing `gh` or no GitHub
remote are all reported there. None of them can block a commit: the hooks warn
on stderr, commit without a link, and leave `sumup.md` in place for the next
attempt.
