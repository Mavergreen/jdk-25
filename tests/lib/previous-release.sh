# platform: host-agnostic -- sourced, never run: tr and sed only, with no shipyard, so the 10.9 guest can source it
#   usage: . tests/lib/previous-release.sh; previous_release_tag ROOT
#          Prints ROOT/components/previous-release/version's tag, or `none` when it reads none. Returns 1,
#          saying why on stderr, when the pin is unreadable, empty, or neither none nor a release tag
#          (N.N...-mavericks.N), so a broken pin can never pass for "no previous release".
# spec: PORT.md ruling R52 -- only `none` skips the upgrade leg
previous_release_tag() {
  _pr_file="$1/components/previous-release/version"
  [ -r "$_pr_file" ] || { echo "no readable $_pr_file" >&2; return 1; }
  _pr="$(tr -d '[:space:]' < "$_pr_file")"
  if [ "$_pr" = none ] || printf '%s\n' "$_pr" | grep -xE '[0-9]+(\.[0-9]+)+-mavericks\.[0-9]+' > /dev/null; then
    printf '%s\n' "$_pr"; return 0
  fi
  echo "$_pr_file holds '$_pr', neither none nor a release tag" >&2; return 1
}
