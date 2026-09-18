## GitHub issue writing style

These apply to any `gh issue create`, `gh pr create`, `gh issue comment`, or
`gh pr comment` body, whether or not the project has a GitHub Projects
board.

### Markdown in HEREDOC bodies - never escape backticks

When writing an issue/PR/comment body via:

```bash
gh issue create --body "$(cat <<'EOF'
...
EOF
)"
```

...the **single-quoted** `<<'EOF'` already disables shell expansion.
Backticks, `$`, `"`, and `\` are already literal. Do NOT add `\` before
them - the backslashes survive into the body verbatim and break the
rendered Markdown. A triple-backtick fence "escaped" as `` \`\`\`tsx ``
renders on GitHub as the literal text `` \`\`\`tsx `` instead of opening a
code block.

Rule: inside `<<'EOF'` ... `EOF`, write Markdown the way you'd write it in
a `.md` file. No escapes. Ever.

### Never hard-wrap prose in issue/PR/comment bodies

GitHub renders issue, PR, and comment bodies differently from files in the
repo. A file rendered from the repo (a README, a doc under `docs/`) follows
CommonMark: a single `\n` inside a paragraph is a soft break and collapses
to a space. Issue/PR/comment bodies do **not** follow that rule - GitHub
renders every single `\n` there as a literal `<br>`. Text hand-wrapped at
~80 columns will render as one choppy line per source line instead of a
flowing paragraph.

Rule: write each paragraph as a single unwrapped line - no interior
newlines - and use a blank line only to separate paragraphs, list items, or
headings. This applies to prose paragraphs specifically; list items, code
fences, and headings still each take their own line as normal Markdown
requires.

### Issue body shape

For bug and audit findings, use this shape by default:

1. **What can go wrong** - describe the bad behavior in product terms.
2. **Example** - give a concrete action sequence or data scenario.
3. **Why this matters** - explain the user, admin, or data impact.
4. **Where this seems to happen** - name files/functions after the problem
   is clear.
5. **Expected behavior** - describe what the system should do instead.
6. **Fix idea** - keep this short and clearly separate from the problem.

Avoid opening with implementation-detail phrasing (race conditions,
compare-and-swap, ORM internals, etc.) - that can appear in a technical
section, but the title and summary should say what a person would observe.

### Issue title format

Plain language - never commit-style prefixes like `fix(web):` or
`feat(bot):` in an issue title.
