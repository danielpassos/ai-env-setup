**Two-step pattern** (re-verify option IDs via `gh project
field-list {{PROJECT_NUMBER}} --owner {{OWNER}} --format json` if the board structure
changes):

```bash
# Step 1: create the issue
gh issue create --title "..." --body "..."  # -> returns the issue URL

# Step 2: add to the board + assign column
ITEM_ID=$(gh project item-add {{PROJECT_NUMBER}} --owner {{OWNER}} \
  --url <issue-url-from-step-1> --format json | jq -r .id)
gh project item-edit \
  --project-id {{PROJECT_ID}} \
  --field-id {{STATUS_FIELD_ID}} \
  --id "$ITEM_ID" \
  --single-select-option-id <column-option-id>
```
