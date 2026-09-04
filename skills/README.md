# robur skills

Agent Skills that teach a coding agent to use robur. Standard format: one
directory per skill, each with a `SKILL.md` carrying YAML frontmatter
(`name`, `description`). Nothing here is robur-specific plumbing — any harness
that reads the Agent Skills convention can load them.

| Skill | Use it for |
|---|---|
| `robur-plan` | Authoring a `PLAN.md` the loop can execute unattended — task schema, tier tags, the 40-line cap, Given/When/Then acceptance |
| `robur` | Operating the loop — setup, running, watching, and diagnosing a stall, a red gate or a quota burn |

The two are deliberately split along the line the user is standing on:
`robur-plan` is *before* a run, `robur` is *during and after* one. A single
skill covering both would load planning guidance into a debugging session and
vice versa.

## Install

```sh
skills/install.sh            # symlink into every harness found
skills/install.sh --copy     # copy instead of symlink
skills/install.sh --dry-run  # print what would happen
```

Symlinks are the default so a `git pull` updates the installed skills. Use
`--copy` for a machine where the repo will not stay put.

Targets, each installed only if its parent directory already exists:

| Harness | Path |
|---|---|
| Claude Code | `~/.claude/skills/` |
| pi | `~/.pi/agent/skills/` |
| Codex | `~/.codex/skills/` |

To install by hand, symlink the skill directory into whichever of those you use:

```sh
ln -s "$PWD/skills/robur-plan" ~/.claude/skills/robur-plan
```

## Superseding the old ratchet skill

`robur-plan` replaces `ratchet-plan`. The installer detects a `ratchet-plan`
already installed and tells you, but **never removes it** — a skill you did not
install is not one this script should delete. Remove it yourself once you are
happy:

```sh
rm ~/.claude/skills/ratchet-plan
```

Leaving both installed is safe but wasteful: the descriptions overlap, so an
agent may load either, and the ratchet copy describes a tool whose on-disk
names and prompt assembly have since changed.
