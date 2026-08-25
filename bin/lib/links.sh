#!/usr/bin/env bash
# Symlinks a selected tool's config into its home dir, per the `links` list
# for that tool in manifest/tools.yaml. Each link's `source` is a path
# relative to the repo root, so it can point at tool-specific config
# (config/<id>/...) or a shared asset (skills/) equally well.

tools::sync_links() {
  local id="$1"
  local home count
  home="$(tools::home "$id")"
  count="$(tools::field_or_empty "$id" '.links | length')"

  if [[ -z "$count" || "$count" -eq 0 ]]; then
    log_info "$(tools::name "$id"): no config links declared, skipping"
    return 0
  fi

  local i src_rel tgt_rel expand src tgt entry
  for ((i = 0; i < count; i++)); do
    src_rel="$(tools::field_or_empty "$id" ".links[$i].source")"
    tgt_rel="$(tools::field_or_empty "$id" ".links[$i].target")"
    expand="$(tools::field_or_empty "$id" ".links[$i].expand")"

    src="$AI_ENV_SETUP_HOME/$src_rel"
    tgt="$home/$tgt_rel"

    [[ -e "$src" ]] || die "$(tools::name "$id"): link source missing at $src"

    if [[ "$expand" == "true" ]]; then
      for entry in "$src"/*; do
        [[ -e "$entry" ]] || continue
        backup_and_symlink "$entry" "$tgt/$(basename "$entry")"
      done
    else
      backup_and_symlink "$src" "$tgt"
    fi
  done
}
