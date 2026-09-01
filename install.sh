#!/usr/bin/env bash
# install.sh - make this repo's skills available to every AI harness on this
# machine. Skill-native harnesses get the skill directory; the rest get a short
# pointer block spliced into the instruction file they already read.
#
#   ./install.sh                 all skills in this repo, every harness found
#   ./install.sh gptcleaner      just one skill (repeatable)
#   ./install.sh ~/skills/mine   a skill living outside this repo, by path
#   ./install.sh --list          show skills and detected harnesses
#   ./install.sh --all           also install for harnesses that aren't set up yet
#   ./install.sh --project [DIR] install into a repo (.claude/skills, AGENTS.md, ...)
#   ./install.sh --copy          copy instead of symlink (symlink is the default)
#   ./install.sh --bin           also put bundled scripts on PATH (~/.local/bin)
#   ./install.sh --dry-run       show what would happen
#   ./install.sh --uninstall     remove everything this script installed
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$ROOT/skills"

MODE=user; LINK=1; DRY=0; UNINSTALL=0; FORCE_ALL=0; ADD_BIN=0; LIST=0
PROJECT_DIR="$PWD"
SELECTED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) MODE=project; [ $# -ge 2 ] && case "$2" in -*) ;; *) PROJECT_DIR="$2"; shift;; esac ;;
    --copy) LINK=0 ;;
    --dry-run|-n) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --all) FORCE_ALL=1 ;;
    --bin) ADD_BIN=1 ;;
    --list) LIST=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) SELECTED="$SELECTED $1" ;;
  esac
  shift
done

# --- which skills -----------------------------------------------------------
# A selection is either a skill name inside this repo, or a path to any
# directory containing a SKILL.md (so skills kept outside the repo still
# install cleanly). Newline-delimited to tolerate spaces in paths.
resolve() {
  local want="$1"
  if [ -f "$want/SKILL.md" ]; then (cd "$want" && pwd); return 0; fi
  if [ -f "$SKILLS_ROOT/$want/SKILL.md" ]; then echo "$SKILLS_ROOT/$want"; return 0; fi
  echo "no such skill: $want" >&2
  echo "  looked in $SKILLS_ROOT/$want and treated it as a path" >&2
  return 1
}

SKILLS=""
if [ -n "$SELECTED" ]; then
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    dir="$(resolve "$want")" || exit 2
    SKILLS="$SKILLS$dir\n"
  done <<< "$(printf '%s\n' $SELECTED)"
else
  for d in "$SKILLS_ROOT"/*/; do
    [ -f "$d/SKILL.md" ] && SKILLS="$SKILLS${d%/}\n"
  done
fi
[ -n "$SKILLS" ] || { echo "no skills found under $SKILLS_ROOT" >&2; exit 1; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

say() { printf '  %-16s %s\n' "$1" "$2"; }
act() { if [ "$DRY" = 1 ]; then printf '  %-16s [dry-run] %s\n' "$1" "$2"; else return 1; fi; }

# --- primitives (operate on $NAME / $SKILL_DIR / $CAPSULE) ------------------
splice() { # $1 = target markdown file
  python3 - "$1" "$NAME" "$UNINSTALL" "$CAPSULE" <<'PY'
import pathlib, sys
target, name, remove = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3] == "1"
begin, end = f"<!-- BEGIN {name} skill -->", f"<!-- END {name} skill -->"
body = pathlib.Path(sys.argv[4]).read_text().strip()
old = target.read_text() if target.exists() else ""
if begin in old and end in old:
    head, rest = old.split(begin, 1)
    _, tail = rest.split(end, 1)
    old = head.rstrip("\n") + "\n" + tail.lstrip("\n")
if remove:
    if not old.strip():
        target.unlink(missing_ok=True)
    else:
        target.write_text(old.rstrip("\n") + "\n")
    sys.exit(0)
target.parent.mkdir(parents=True, exist_ok=True)
sep = "\n\n" if old.strip() else ""
target.write_text(old.rstrip("\n") + sep + begin + "\n" + body + "\n" + end + "\n")
PY
}

installed_at() { # kind, path
  case "$1" in
    skill)   [ -e "$2" ] || [ -L "$2" ] ;;
    rule)    [ -e "$2" ] ;;
    capsule) [ -f "$2" ] && grep -q "BEGIN $NAME skill" "$2" ;;
  esac
}

do_skill() { # label, dest
  if [ "$UNINSTALL" = 1 ]; then
    act "$1" "remove $2" || rm -rf "$2"; say "$1" "removed  $2"; return 0
  fi
  act "$1" "$2" && return 0
  mkdir -p "$(dirname "$2")"; rm -rf "$2"
  if [ "$LINK" = 1 ]; then ln -s "$SKILL_DIR" "$2"; else cp -R "$SKILL_DIR" "$2"; fi
  say "$1" "$2"
}

do_capsule() { # label, file
  if [ "$UNINSTALL" = 1 ]; then
    act "$1" "unsplice $2" || splice "$2"; say "$1" "cleaned  $2"; return 0
  fi
  act "$1" "$2" && return 0
  splice "$2"; say "$1" "$2"
}

do_rule() { # label, file, frontmatter
  if [ "$UNINSTALL" = 1 ]; then
    act "$1" "remove $2" || rm -f "$2"; say "$1" "removed  $2"; return 0
  fi
  act "$1" "$2" && return 0
  mkdir -p "$(dirname "$2")"
  { printf '%s\n' "$3"; cat "$CAPSULE"; } > "$2"
  say "$1" "$2"
}

frontmatter() { # flavour
  local desc; desc="$(sed -n 's/^description: //p' "$SKILL_DIR/SKILL.md" | head -1 | cut -c1-180)"
  case "$1" in
    cursor)   printf -- '---\ndescription: %s\nalwaysApply: false\n---\n' "$desc" ;;
    windsurf) printf -- '---\ntrigger: model_decision\ndescription: %s\n---\n' "$desc" ;;
  esac
}

target() { # label, probe, kind, path, [frontmatter flavour]
  local label="$1" probe="$2" kind="$3" path="$4" flav="${5:-}"
  if [ "$UNINSTALL" = 1 ] && ! installed_at "$kind" "$path"; then return 0; fi
  if [ -e "$probe" ] || [ "$FORCE_ALL" = 1 ]; then
    if [ "$LIST" = 1 ]; then say "$label" "$path"; return 0; fi
    case "$kind" in
      skill)   do_skill   "$label" "$path" ;;
      capsule) do_capsule "$label" "$path" ;;
      rule)    do_rule    "$label" "$path" "$(frontmatter "$flav")" ;;
    esac
  elif [ "$LIST" = 1 ]; then
    say "$label" "(harness not installed)"
  fi
}

targets_for_skill() {
  if [ "$MODE" = project ]; then
    local P; P="$(cd "$PROJECT_DIR" && pwd)"
    target "Claude Code"    "$P" skill   "$P/.claude/skills/$NAME"
    target "AGENTS.md"      "$P" capsule "$P/AGENTS.md"
    target "Copilot"        "$P" capsule "$P/.github/copilot-instructions.md"
    target "Cursor"         "$P" rule    "$P/.cursor/rules/$NAME.mdc"  cursor
    target "Windsurf"       "$P" rule    "$P/.windsurf/rules/$NAME.md" windsurf
    target "Gemini CLI"     "$P" capsule "$P/GEMINI.md"
    target "Cline"          "$P" capsule "$P/.clinerules/$NAME.md"
  else
    target "Claude Code"    "$HOME/.claude"           skill   "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/$NAME"
    target "Codex CLI"      "$HOME/.codex"            capsule "$HOME/.codex/AGENTS.md"
    target "Gemini CLI"     "$HOME/.gemini"           capsule "$HOME/.gemini/GEMINI.md"
    target "Cursor"         "$HOME/.cursor"           rule    "$HOME/.cursor/rules/$NAME.mdc" cursor
    target "Windsurf"       "$HOME/.codeium/windsurf" rule    "$HOME/.codeium/windsurf/memories/$NAME.md" windsurf
    target "OpenCode"       "$HOME/.config/opencode"  capsule "$HOME/.config/opencode/AGENTS.md"
    target "Continue"       "$HOME/.continue"         capsule "$HOME/.continue/rules/$NAME.md"
    target "Amp"            "$HOME/.config/amp"       capsule "$HOME/.config/amp/AGENTS.md"
  fi
}

# --- run --------------------------------------------------------------------
echo
if   [ "$LIST" = 1 ];      then echo "Skills in $SKILLS_ROOT:"
elif [ "$UNINSTALL" = 1 ]; then echo "Uninstalling from $HOME and friends..."
else echo "Installing from $SKILLS_ROOT"; fi
[ "$MODE" = project ] && echo "Project: $(cd "$PROJECT_DIR" && pwd)"
echo

while IFS= read -r SKILL_DIR; do
  [ -n "$SKILL_DIR" ] || continue
  NAME="$(basename "$SKILL_DIR")"
  CAPSULE="$TMPD/$NAME.capsule"
  if [ -f "$SKILL_DIR/adapters/capsule.md" ]; then
    sed "s#{{SKILL_DIR}}#$SKILL_DIR#g" "$SKILL_DIR/adapters/capsule.md" > "$CAPSULE"
  else
    printf '## %s\n\nSee %s/SKILL.md\n' "$NAME" "$SKILL_DIR" > "$CAPSULE"
  fi
  out="$(targets_for_skill)"
  if [ -n "$out" ]; then printf '%s:\n%s\n' "$NAME" "$out"; fi
done <<< "$(printf "$SKILLS")"

# --- bundled scripts on PATH ------------------------------------------------
if [ "$ADD_BIN" = 1 ] || [ "$UNINSTALL" = 1 ]; then
  binout=""
  while IFS= read -r SKILL_DIR; do
    [ -n "$SKILL_DIR" ] || continue
    for s in "$SKILL_DIR"/scripts/*.py; do
      [ -f "$s" ] || continue
      cmd="$(basename "$s" .py)"; BIN="$HOME/.local/bin/$cmd"
      if [ "$UNINSTALL" = 1 ]; then
        [ -L "$BIN" ] || continue
        act "$cmd" "remove $BIN" || rm -f "$BIN"
        binout="$binout  $(printf '%-16s removed  %s' "$cmd" "$BIN")
"
      else
        act "$cmd" "$BIN" || { mkdir -p "$(dirname "$BIN")"; ln -sf "$s" "$BIN"; }
        binout="$binout  $(printf '%-16s %s' "$cmd" "$BIN")
"
      fi
    done
  done <<< "$(printf "$SKILLS")"
  if [ -n "$binout" ]; then
    printf 'PATH:\n%s' "$binout"
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  note: ~/.local/bin is not on your PATH" ;; esac
  fi
fi

echo
if [ "$LIST" = 1 ]; then
  :
elif [ "$UNINSTALL" = 1 ]; then
  echo "Done. Removed the skills and every pointer block."
else
  echo "Done. Harnesses that read SKILL.md load the full skill; the rest got a"
  echo "pointer block per skill, marked with <!-- BEGIN <name> skill --> so"
  echo "./install.sh --uninstall removes it cleanly."
fi
