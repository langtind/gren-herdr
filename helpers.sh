#!/usr/bin/env bash

# True when NAME is a gren PR/MR reference (pr:<n> / mr:<n>) that gren resolves
# itself via `gren create <ref>`. Git branch names can't contain ':', so these
# must be passed to gren as-is, never with -n/--branch as a plain branch name.
gren_is_prref() {
  case $1 in
    pr:*|mr:*) return 0 ;;
    *) return 1 ;;
  esac
}
