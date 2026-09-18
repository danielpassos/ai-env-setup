## Commit conventions

Commit format: `type(scope): description`

- Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
- Scope: name it after the part of the codebase the commit touches (e.g. a
  package, app, or module). The exact scope list is project-specific -
  infer it from the project's existing commit history rather than
  inventing one.

Rules:

- **Subject line ≤ 70 characters.** GitHub's web UI truncates anything past
  ~72 characters with an ellipsis on every list view (history, PRs, blame,
  search). If `type(scope): description` doesn't fit, shorten the
  description, drop the scope, or split the change.
- One logical change per commit.
- Never commit with failing tests or a broken build/type-check.
- `git add` specific files - never `git add -A` or `git add .`.
