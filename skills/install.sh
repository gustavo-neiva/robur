#!/usr/bin/env bash
# Install robur's skills into every agent harness on this machine.
#
# Symlinks by default so `git pull` updates them in place. Only installs into
# a harness whose skills-parent directory already exists — creating
# ~/.codex/skills on a machine with no Codex would be litter, not help.
set -euo pipefail

SKILLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=link
DRY=0

for arg in "$@"; do
  case "$arg" in
    --copy)    MODE=copy ;;
    --dry-run) DRY=1 ;;
    -h|--help)
      sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      echo
      echo "usage: install.sh [--copy] [--dry-run]"
      exit 0 ;;
    *) echo "unknown option: $arg (see --help)" >&2; exit 1 ;;
  esac
done

# harness label : parent that must exist : skills dir
TARGETS=(
  "Claude Code:$HOME/.claude:$HOME/.claude/skills"
  "pi:$HOME/.pi/agent:$HOME/.pi/agent/skills"
  "Codex:$HOME/.codex:$HOME/.codex/skills"
)

SKILLS=()
for d in "$SKILLS_DIR"/*/; do
  [ -f "${d}SKILL.md" ] && SKILLS+=("$(basename "$d")")
done

if [ ${#SKILLS[@]} -eq 0 ]; then
  echo "no skills found in $SKILLS_DIR" >&2
  exit 1
fi

run() { if [ "$DRY" = 1 ]; then echo "    would: $*"; else "$@"; fi; }

installed_any=0
for entry in "${TARGETS[@]}"; do
  label="${entry%%:*}"; rest="${entry#*:}"
  parent="${rest%%:*}"; dest="${rest#*:}"

  if [ ! -d "$parent" ]; then
    echo "$label: not installed here (no $parent) — skipping"
    continue
  fi

  installed_any=1
  echo "$label -> $dest"
  run mkdir -p "$dest"

  for skill in "${SKILLS[@]}"; do
    target="$dest/$skill"
    # A real directory we did not create is someone's own edited copy.
    # Replacing it silently would lose their work.
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      echo "    $skill: a real directory is already there — leaving it alone"
      continue
    fi
    [ -L "$target" ] && run rm -f "$target"
    if [ "$MODE" = copy ]; then
      run cp -R "$SKILLS_DIR/$skill" "$target"
      echo "    $skill: copied"
    else
      run ln -s "$SKILLS_DIR/$skill" "$target"
      echo "    $skill: linked"
    fi
  done

  # Point out the superseded skill; never delete what we did not install.
  if [ -e "$dest/ratchet-plan" ]; then
    echo "    note: ratchet-plan is still installed and is superseded by robur-plan."
    echo "          remove it when ready:  rm '$dest/ratchet-plan'"
  fi
done

if [ "$installed_any" = 0 ]; then
  echo "no supported agent harness found (looked for ~/.claude, ~/.pi/agent, ~/.codex)" >&2
  exit 1
fi

[ "$DRY" = 1 ] && echo "(dry run — nothing changed)"
exit 0
