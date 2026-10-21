# prel

A git management toolkit for configuring commit attribution and hooks across repositories.

## Quick Start

Run from any directory in a git repository:

```bash
prel                    # the command list
prel init register      # set this repository up
prel init status        # what a commit here would file
```

## Installing

A release carries a `.deb`, which is the shortest way onto a Debian or Ubuntu
machine. `apt` rather than `dpkg -i`, so the dependencies are resolved:

```bash
sudo apt install ./prel_0.1.0_all.deb
```

The package puts the tree under `/usr/share/prel` and symlinks `/usr/bin/prel`
to it, so `prel` works from anywhere and the hooks, the skill and the memories
are shared from there. It is `Architecture: all` - prel is shell, so there is
nothing to compile and one file fits every machine.

From a clone instead, put `prel.sh` on the `PATH` under the name `prel`:

```bash
git clone https://github.com/pdulvp/prel.git
sudo ln -s "$PWD/prel/prel.sh" /usr/local/bin/prel
```

Either way `prel` resolves the symlink before it looks for `scripts/`, so it
finds its own tree rather than the directory the link happens to sit in. A
clone is the better one to work from: the registrations are links back into it,
so an edit there is live everywhere it is registered, with nothing to reinstall.

## Commands

### prel usage
Show detailed help for all available commands.

### prel init
Register everything prel shares with a repository, in one go.

```bash
prel init usage             # Show help
prel init register          # Register the hooks, the skill and the memories
prel init register --copy   # Install the skill as a copy instead of a symlink
prel init unregister        # Remove the hooks and the memories from this repo
prel init status            # The state of all three, and what the next commit
                            # would file
```

prel shares three things with a repository, each with a command of its own: the
hooks that file the completed work plans (`prel hooks`), the skill that is the
format they read (`prel skills`), and the memories that make a session produce
something to file (`prel memory`).

All three are needed before `prel issue-from-plans` does anything, and missing
one leaves the feature inert without saying so - a repository with no memories
grows no plans, so there is never a sum-up to file, so no issue is ever filed.
`prel init` is the one command to run in a new repository, and the one to ask
afterwards.

`register` is safe to run again: each step reports what was already in place,
and leaves alone any local file of the same name that is not prel's. A step that
could not do its work says so and makes the whole command exit non-zero, because
a half-registered repository is the failure this command exists to surface.

`unregister` removes only what belongs to this repository - the hooks and the
memories. The skill lives in the user's skills directory and is shared by every
repository, so it is kept; remove it with `prel skills unregister`.

`status` adds the report of `prel issue-from-plans status` to the three, so one
command answers whether a commit here would file an issue, and why not.

### prel init-authored-hooks (or **hooks**)
Manage git hooks from the prel project.

```bash
prel init-authored-hooks usage          # Show help
prel init-authored-hooks register       # Set core.hooksPath to prel/.githooks
prel init-authored-hooks unregister     # Remove core.hooksPath setting
prel init-authored-hooks status         # Show whether they are registered

# Shortcut:
prel hooks register
prel hooks unregister
prel hooks status
```

`status` reports `core.hooksPath`, whether each hook is executable - git skips
one that is not, in silence - and what `commit.cleanup` will do to a `#12`
subject.

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
follows, written by the Claude Code session that finishes the work - installed
along with the rest by `prel init register`.

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

### prel release
Move the VERSION file on, tag it, push it and publish the release.

```bash
prel release usage              # Show help
prel release artifacts          # Say what prel.artifacts matches, do nothing
prel release artifacts 1.0.1    # The same, for a version not yet in the file
prel release 1.0.1              # Bump, commit, tag, push, publish
prel release 1.0.1 -n           # Show every step, change nothing
prel release 1.0.1 -y           # Do not ask about uncommitted changes
prel release 1.0.1 -m "..."     # Message for the commit and the tag
prel release 1.0.1 --draft      # Publish the GitHub release as a draft
prel release 1.0.1 --no-build   # Upload the artifacts without building them
prel release 1.0.1 --no-assets  # Build nothing, upload nothing
prel release 1.0.1 --no-release # Commit, tag and push, publish nothing
```

For a project that keeps its version in a `VERSION` file at its root - three
numbers in a file, which the build reads and nothing has to parse out of source
code - a release is that file moved on and the commit it was moved in made
public. Seven steps, stopping at the first that fails:

1. write `1.0.1` into the `VERSION` file
2. commit that file alone
3. tag the commit, annotated, as `v1.0.1`
4. build the artifacts, where `prel.buildCommand` says how
5. push the branch and the tag
6. create the GitHub release, its notes the commits since the last tag
7. upload the artifacts in `prel.artifacts`, then take the release out of
   draft now that it has them

#### Release artifacts

Steps 4 and 7 are there for a project whose build produces files that belong on
the release - a `.deb`, a Windows `.zip` - and are skipped entirely by one that
has not asked for them:

```bash
git config prel.buildCommand "cmake --build build --target release"
git config prel.artifacts "build/*.deb build-win/*.zip"
```

`prel.artifacts` is a whitespace-separated list of globs read from the
repository root; paths with spaces in them are not expressible in it.

A pattern can also name the release it is for, instead of globbing over every
release ever built - `build/myapp-*.deb` happily uploads the `.deb` from last
time alongside this one:

```bash
git config prel.artifacts 'build/myapp-${version}.deb dist/myapp-${tag}.zip'
```

`${version}` is the version being released, `1.0.1`, and `${tag}` the tag it
gets, `v1.0.1`; the bare `$version` and `$tag` work too. Set them in **single
quotes**, so the shell leaves the names for prel to fill in. They are filled in
by plain string replacement rather than by a shell: a pattern becomes a
filename, and nothing in it is allowed to run. `prel.buildCommand` *is* a shell
command, and sees the same two as `$version` and `$tag`.

A misspelt name is left as it stands, matches no file and so stops the release
before the push, naming the two it knows. Attempting a release is a poor way to
discover a typo, though, so there is a command that only looks:

```console
$ prel release artifacts
artifacts: build/myapp-${version}.deb build-win/myapp-${tag}.zip
version:   1.0.1 (from VERSION)
tag:       v1.0.1

filled in:
  build/myapp-${version}.deb -> build/myapp-1.0.1.deb
  build-win/myapp-${tag}.zip -> build-win/myapp-v1.0.1.zip
would upload:
  build/myapp-1.0.1.deb
matched nothing:
  build-win/myapp-v1.0.1.zip
  a release would build them first: cmake --build build --target release

1 pattern(s) matched nothing; a release would stop before the push
```

`prel release artifacts` needs none of what a release needs - no network, no
`gh`, no free tag, nothing written and nothing built. The version is the one in
the `VERSION` file as it stands, or the one given as `prel release artifacts
1.0.1` for a release not yet made. It exits non-zero where a pattern matched no
file, so a build script can gate on it.

Two things about the order are deliberate. The build runs **before the push**,
while the commit and the tag are still only local: a build that fails there
undoes both and leaves nothing published, rather than a public tag whose
release holds no files and a version that cannot be released again. And the
release is created as a **draft** whenever there are artifacts, taken out of
draft only once they are all up, so it is never visible without them -
`--draft` simply leaves it there.

A pattern that matches no file stops the release, before the push, for the same
reason: that is how a release goes out missing the one artifact nobody thought
to check for. The upload is `--clobber`, so a release left half-uploaded by a
dropped connection can be finished by running the upload again.

`--no-build` uploads the artifacts as they already are on disk, for a build
done by hand or by CI. `--no-assets` skips both steps, and `--no-release`
implies it - with nowhere to upload to, the build would be work for nothing.

Nothing is touched before every precondition is checked: a `VERSION` file to
move, a three-number version (a `-rc1` suffix allowed), a branch rather than a
detached HEAD, a tag free both here and on the remote, and a usable `gh` unless
`--no-release` says not to publish. A release half made is worse than one not
started - which is also why a failure after the commit says what is local and
what is pushed.

Uncommitted changes are not carried into a release. Where the tree has any, the
command lists them and asks, since committing the version alone leaves them
exactly where they were:

```
This tree has changes that will NOT be part of the release:
   M app.txt
  ?? scratch.txt

Only VERSION would be committed; these stay exactly as they are.
Release 1.0.1 anyway? [y/N]
```

`-y` answers yes in advance, and no terminal to ask on is an answer of no - a
command that pushes and publishes does not take a redirected pipe for consent.

The tag is `v<x.y.z>`, or the version alone where `prel.tagPrefix` is set to an
empty string. The file is `VERSION`, or the path in `prel.versionFile`. The
release commit is made with `PREL_SKIP_ISSUE` set, so it never spends the issue
that `prel issue-from-plans` is holding for the next real commit.

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

### prel init-memory (or **memory**)
Share prel's Claude Code memories with a repository.

```bash
prel init-memory usage         # Show help
prel init-memory register      # Link prel's memories into this project
prel init-memory unregister    # Remove them from this project
prel init-memory status        # Show which ones are linked

# Shortcut:
prel memory register
```

Claude Code keeps its memories per project, under
`$CLAUDE_CONFIG_DIR/projects/<the repo path with dashes>/memory`. A convention
shared by several repositories would have to be written there once per
repository, and would then drift.

`register` links the memories shipped in `prel/memory` into the current
repository's memory directory and splices their index lines into its
`MEMORY.md`, between the markers prel owns. The memories themselves stay in the
prel checkout: that is where they are edited, and every registered repository
sees the edit at once.

Memories belonging to one repository alone - its build, its stack - stay where
they are. prel only ever rewrites its own block of `MEMORY.md`, and refuses to
touch a local file of the same name that says something different.

Shipped today:

- **write-plan-before-coding** - write the steps to `docs/plans/plan.md` first,
  mark it complete, sum it up, archive it.
- **resume-from-plan-file** - on "continue where you left off", read the newest
  plan in `docs/plans/` before anything else.

Both are the convention `prel issue-from-plans` and the `plan-summary` skill are
built around, so a repository using those wants them.

## Direct Script Usage

Scripts can also be run directly from the `scripts/` directory:

```bash
/mnt/Data/Works/prel/scripts/switch-author.sh claude
/mnt/Data/Works/prel/scripts/init-authored-hooks.sh register
/mnt/Data/Works/prel/scripts/recommit-last.sh 3
/mnt/Data/Works/prel/scripts/exclude-from-git.sh secrets.env
/mnt/Data/Works/prel/scripts/issue-from-plans.sh status
/mnt/Data/Works/prel/scripts/init-skills.sh register
/mnt/Data/Works/prel/scripts/init-memory.sh register
/mnt/Data/Works/prel/scripts/init.sh status
```

`scripts/init.sh` drives the other commands, so run directly it loads its
siblings from the same directory first.

## Packaging

`packaging/build-deb.sh` builds the `.deb`:

```bash
packaging/build-deb.sh            # at the version in the VERSION file
packaging/build-deb.sh 0.2.0      # at that version instead
```

It writes `build/prel_<version>_all.deb`, staging the package tree beside it.
Both are gitignored. `dpkg-deb` is all it needs - no `debian/` directory, no
`dpkg-buildpackage`, no changelog, since an architecture-independent shell
package has nothing those would do for it. There is no apt repository: the
`.deb` goes on the release page and is installed by hand.

It is in `packaging/` rather than `scripts/` on purpose. `prel.sh` sources
every `scripts/*.sh` and turns it into a command, so a build script there
would ship a `prel build-deb` to everyone who installs the package - a command
about prel's own clone, in the hands of people who do not have one.

The payload is named file by file in the script, a whitelist rather than a
blacklist: a top-level directory added to the repository later has to be named
there before it ships. The package also sets its own modes instead of
inheriting the clone's, which are group-writable and in places mode 770 -
installed root-owned under `/usr/share`, that would leave
`/usr/share/prel/prel.sh` unreadable to every user but root, and the package
would install cleanly and then refuse to run.

`prel release` builds and attaches it through the two settings every project
configures for itself. They are git config, so they live in `.git/config` and
cannot be committed - git will not let a tracked file set them - which means
one clone of prel has them and a fresh clone does not:

```bash
git config prel.buildCommand 'packaging/build-deb.sh ${version}'
git config prel.artifacts    'build/prel_${version}_all.deb'
```

Single quotes both times, so git stores the `${version}` placeholder rather
than today's version: `prel release` fills it in at release time, which is how
the build is told which version it is building and how the artifact is found
once it has. `prel release artifacts` says what they resolve to without
building anything.

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
- `memory/*.md` - Claude Code memories shared across repositories, plus the
  `INDEX.md` lines spliced into each project's `MEMORY.md`

Read from the repository being worked on, not from prel:

- `VERSION` - the three numbers `prel release` moves on, or the path in the
  repository's `prel.versionFile` git config
- `docs/plans/` - the work plans `prel issue-from-plans` files, or the path in
  its `prel.plansDir`
- `prel.buildCommand` - the command `prel release` runs to build the release
  artifacts, unset in a project whose release is the tag and nothing else
- `prel.artifacts` - the globs of the files it then uploads to the release,
  where `${version}` and `${tag}` stand for the release being made

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

`prel init-skills register` and `prel init-memory register` work the same way
for the agent skills and the shared memories: links in `~/.claude/skills` and in
the project's memory directory rather than a copy per project, so the prel
checkout stays the single place they are edited.

Those three registrations are independent, and the issue filing needs all of
them, so `prel init` runs them together and `prel init status` reports them
together - a repository missing one looks exactly like a repository where the
hooks simply had nothing to do.

## License

MIT - see [LICENSE](LICENSE). The package installs it as
`/usr/share/doc/prel/copyright`, where Debian policy puts it.
