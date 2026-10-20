# prel

A git management toolkit for configuring commit attribution and hooks across repositories.

## Quick Start

Run from any directory in a git repository:

```bash
prel.sh
```

## Commands

### prel usage
Show detailed help for all available commands.

### prel init-authored-hooks (or **hooks**)
Manage git hooks from the prel project.

```bash
prel init-authored-hooks usage          # Show help
prel init-authored-hooks register       # Set core.hooksPath to prel/.githooks
prel init-authored-hooks unregister     # Remove core.hooksPath setting

# Shortcut:
prel hooks register
prel hooks unregister
```

Registering also sets `commit.cleanup` to `scissors`, and unregistering puts it
back. That setting is what lets a commit subject start with the `#12` of the
issue `prel issue-from-plans` files: git cleans the message up *after* the hooks
have run, and its default mode drops every line starting with the comment
character - the subject included. Under `scissors` only what sits below the
scissors line is dropped, so the help text still goes and the subject stays.

New hooks need no re-register: `core.hooksPath` points at the prel checkout, so
a hook added there is live in every repository that registered it. Which is why
each hook is inert where it has nothing to do.

### prel switch-author (or **sa**)
Switch commit author and co-author mode.

```bash
prel switch-author usage    # Show help
prel switch-author          # Show current mode
prel switch-author default  # Use default (no co-author)
prel switch-author claude   # Use Claude mode
prel switch-author mistral  # Use Mistral Vibe mode

# Shortcut:
prel sa claude
prel sa mistral
prel sa default
```

### prel recommit-last (or **recommit**)
Rewrite the last N commits with the current author mode.

```bash
prel recommit-last usage       # Show help
prel recommit-last 3           # Rewrite the last 3 commits
prel recommit-last 3 -n        # Dry run: show what would change

# Shortcut:
prel recommit 3
```

Use it after `prel switch-author` when the last commits were made under the
wrong mode:

```bash
prel sa claude          # pick the mode the commits should have carried
prel recommit-last 3    # replay the last 3 commits under it
```

Each commit is replayed with the committer of the current mode and with its
message run back through the `prepare-commit-msg` hook, so a stale
`Co-Authored-By` trailer is replaced by the one the current mode asks for.
Trailers prel never wrote (real human co-authors) are left alone.

Author identity, author date and commit date are all preserved - only the
committer and the message change. The working tree and the index are never
touched, so this works on a dirty repository. Rewritten commits get new
hashes: the previous HEAD is printed and kept in the reflog, and a branch that
was already pushed needs a force push afterwards. Commit signatures do not
survive the rewrite.

### prel exclude-from-git (or **exclude**)
Rewrite history to drop files that should never have been committed.

```bash
prel exclude-from-git usage                   # Show help
prel exclude-from-git secrets.env             # Drop it from the whole history
prel exclude-from-git build/ '*.log'          # Pathspecs: directories and globs
prel exclude-from-git secrets.env -n          # Dry run: show what would change
prel exclude-from-git secrets.env --last 5    # Only rewrite the last 5 commits

# Shortcut:
prel exclude secrets.env
```

Use it when a file was committed that should not have been:

```bash
prel exclude-from-git secrets.env   # replay the history without it
echo secrets.env >> .gitignore      # and keep it out from now on
```

Each commit is replayed without the given paths. Author identity, committer
identity, author date and commit date are all kept as they are, and so is every
commit message: only the trees change. The `prepare-commit-msg` hook is
deliberately not run, so no `Co-Authored-By` trailer is added or removed here -
that is what `prel recommit-last` is for. Commits the paths never appeared in
keep their original hash.

A commit left with nothing in it is dropped, unless `--keep-empty` is given;
commits that were already empty are kept either way, and merge commits are never
dropped.

The files stay on disk: they are only removed from history and, unless
`--keep-index` is given, from the index, so the next commit does not add them
straight back. Paths are read relative to the directory the command is called
from, like any other git command.

Rewritten commits get new hashes: the previous HEAD is printed and kept in the
reflog, and a branch that was already pushed needs a force push afterwards. The
old objects stay in the repository until the reflog is expired and `git gc` runs
(the command prints how). Commit signatures do not survive the rewrite.

### prel issue-from-plans (or **issues**)
File the completed work plans of a repository as a GitHub issue, at commit time.

```bash
prel issue-from-plans usage      # Show help
prel issue-from-plans status     # What the next commit would file
prel issue-from-plans dry-run    # The issue and the message in full

# Shortcut:
prel issues status
```

In a repository that keeps work plans under `docs/plans/`, the prel hooks file
every plan marked `status: complete` and not yet carrying an `issue:` field as
**one** GitHub issue, and put its number in front of the commit subject:

```
#12 Paquetage Windows et équilibrage des rivaux

- zip Windows avec les DLL de Qt, les greffons et le runtime mingw
- huit compétences par rival, XP rééquilibrée
```

One issue covers the whole batch - its body is the sum-up followed by one
section per plan - because a plan and a commit rarely line up one to one. The
plans themselves stay out of git: the issue is what remains of them.

`docs/plans/sumup.md` is the trigger and supplies the wording. Its `# title`
line becomes the issue title and the commit subject, and what follows becomes
the commit body and the issue's lead. Without that file nothing is filed and the
commit is an ordinary one, which is also what keeps the hooks inert in every
repository that keeps no plans. The `plan-summary` skill is the format it
follows, written by the Claude Code session that finishes the work - install it
with `prel skills register`.

Once a commit carries the issue, `post-commit` stamps `issue: <n>` into each
plan it filed and deletes `sumup.md`.

A subject that already starts with an issue number is left alone, so
`prel recommit-last` - which replays messages back through the hook - and
`git commit --amend` do not file the same work twice. An issue filed for a
commit that never happened is remembered in `.git/prel-pending-issue` and
reused, so quitting the editor leaves no orphan.

Nothing here can stop a commit. A missing `gh`, an unauthenticated `gh`, no
GitHub remote, a `commit.cleanup` that would strip the number, a failing API
call: each is reported on stderr, the commit is made without a link, and
`sumup.md` is left in place for the next attempt. `PREL_SKIP_ISSUE=1 git commit`
skips the whole thing, and so does `git commit --no-verify`.

Plans are read from `docs/plans`, or from the path in the repository's
`prel.plansDir` git config.

### prel init-skills (or **skills**)
Make the prel agent skills available to Claude Code.

```bash
prel init-skills usage            # Show help
prel init-skills register         # Link prel/skills into ~/.claude/skills
prel init-skills register --copy  # Copy them instead of linking
prel init-skills unregister       # Remove them
prel init-skills status           # Show which ones are installed

# Shortcut:
prel skills register
```

Links the skills shipped in `prel/skills` into `$CLAUDE_CONFIG_DIR/skills`
(`~/.claude/skills` by default), so every project loads them, the way
`prel hooks register` shares the hooks. A symlink means an edit in the prel
checkout takes effect at once.

Shipped today:

- **plan-summary** - the format of `docs/plans/sumup.md`, which
  `prel issue-from-plans` turns into a GitHub issue and a commit subject.

## Direct Script Usage

Scripts can also be run directly from the `scripts/` directory:

```bash
/mnt/Data/Works/prel/scripts/switch-author.sh claude
/mnt/Data/Works/prel/scripts/init-authored-hooks.sh register
/mnt/Data/Works/prel/scripts/recommit-last.sh 3
/mnt/Data/Works/prel/scripts/exclude-from-git.sh secrets.env
/mnt/Data/Works/prel/scripts/issue-from-plans.sh status
/mnt/Data/Works/prel/scripts/init-skills.sh register
```

## Configuration Files

- `configs/.gitconfig-claude` - Claude mode attribution
- `configs/.gitconfig-mistral` - Mistral Vibe mode attribution
- `configs/.gitconfig-base` - Base configuration
- `.githooks/prepare-commit-msg` - Files the completed plans as an issue, then
  adds the Co-Authored-By trailer
- `.githooks/commit-msg` - Puts the issue number back in front of the subject
  should it have been edited away
- `.githooks/post-commit` - Stamps the filed plans and consumes their sum-up
- `skills/plan-summary/SKILL.md` - The format of `docs/plans/sumup.md`

## How It Works

The prel project maintains its own set of git configuration files and hooks. When you run `prel switch-author`, it sets the `include.path` in your repository's git config to point to the appropriate prel config file, which then includes the base config and sets committer/co-author information.

Git itself does not read `committer.name` / `committer.email`: those record what
the mode *should* commit as, and `prel recommit-last` is what applies them to
commits that were made under another identity.

Similarly, `prel init-authored-hooks register` sets `core.hooksPath` to use the hooks from the prel project, so all repositories can share the same hook implementations.

The hooks share one rule: they only ever add to a commit, never stop one. Each
is also inert where it has nothing to do - no `commit.coauthor`, no
`docs/plans/sumup.md` - because `core.hooksPath` makes every hook live in every
repository that registered prel, including those that want none of this.

`prel init-skills register` works the same way for the agent skills: a link in
`~/.claude/skills` rather than a copy per project, so the prel checkout stays
the single place they are edited.
