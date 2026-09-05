# Contributing

## Commits

Conventional Commits, without exception. Allowed types: `feat`, `fix`, `docs`,
`style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`. A
breaking change is marked with `!` after the type and `BREAKING CHANGE:` in the
body.

The **PR title** is the critical spot: on a squash merge it becomes the subject
line on `main` and determines the next version.

No AI attribution trailer in commits, PR bodies or author fields.

## Hooks

`lefthook` with the scripts under `scripts/hooks/`:

```bash
brew install lefthook && lefthook install
```

The installation sets up `commit-msg`, `pre-commit` and `pre-push`. The
pre-commit hook compiles nothing; the full contract suites stay in CI. `git
commit --no-verify` is not a way around this: `Commit hygiene` checks the PR
title, the PR body and the commit metadata again on the server.

## Before any change to publication

This repository produces signed package archives. Two rules hold without
exception.

No error suppression on a path that publishes. No `|| true`, no
`continue-on-error`, no warning in place of an abort.

After every publication, the **public** URL is used to verify that the
retrievable artefact matches byte for byte what was built.

## Actions

Pinned by commit SHA only, with the version as a comment behind it. Never `@v4`
or `@main`. Careful: some tags are annotated tag objects; their SHA is immutable
too, but `gh api repos/X/git/commits/<sha>` does not find it. That is not an
error.
