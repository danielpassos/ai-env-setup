## Recoverable errors - retry, don't stop

When a tool call fails mid-task with a recoverable error, retry it up to
**3 times** in the same turn after fixing the obvious cause, before
surfacing it to the user. Surfacing should be the last resort, not the
first reaction - the goal is to finish the task without forcing the user to
hand-hold every minor hiccup.

A "recoverable error" is one with a clear, mechanical fix, including:

- A file-edit tool refuses because the file hasn't been read yet - read the
  file first, then retry the edit.
- A file-edit tool reports its target text isn't unique / not found -
  re-read the surrounding context, expand the match until it's unique,
  retry.
- A shell command hits a transient network failure (DNS, ECONNRESET, fetch
  timeout, a CLI's rate limit) - wait briefly and retry, up to 3 attempts.
  Don't loop on a hard 4xx/5xx that won't change.
- `gh pr create` fails because the branch isn't pushed yet - push, retry.
- `git push` fails because the remote moved - `git fetch && git pull
  --rebase` on the working branch (NOT main), retry. If the working branch
  is in fact the main branch, surface instead - don't auto-rebase shared
  history.
- A type-check or lint fails on a typo just introduced - fix the typo,
  retry.
- A test fails because a mock doesn't include a field just added to a
  type - extend the mock, retry.

Stop and surface (don't retry blindly) when:

- The error is a real semantic bug in the code that was written - fix the
  code, not the call.
- A destructive operation fails (`rm`, `git reset --hard`, force-push,
  etc.) - the user must decide.
- A permission prompt denies the call - adjusting permissions is the user's
  call.
- 3 retries have already been spent.
- The error message is novel with no confident mechanical fix.

Track the retry count silently per error. Don't narrate every retry - just
do the work. Mention the retry only when surfacing the final failure, or
when the fix is non-obvious enough that it's worth flagging.
