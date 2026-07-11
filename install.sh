#!/usr/bin/env bash
set -euo pipefail

REPO="wktkow/codex-antibug-shit-wrapper"
REF=${CODEX_WRAPPER_REF:-main}
INSTALL_DIR=${CODEX_WRAPPER_INSTALL_DIR:-"$HOME/.local/bin"}
MARKER_START="# >>> codex-antifreeze-shit-wrapper >>>"
MARKER_END="# <<< codex-antifreeze-shit-wrapper <<<"
KEYMAP_MARKER_START="# >>> codex-antifreeze keymap >>>"
KEYMAP_MARKER_END="# <<< codex-antifreeze keymap <<<"
REAL_CODEX_PATH=""

say() {
  printf 'codex wrapper installer: %s\n' "$*"
}

die() {
  printf 'codex wrapper installer: %s\n' "$*" >&2
  exit 1
}

is_managed_wrapper() {
  local candidate=$1

  [ -f "$candidate" ] || return 1
  grep -Fq 'codex-antifreeze-shit-wrapper managed executable' "$candidate" 2>/dev/null &&
    return 0
  grep -Fq 'find_real_codex()' "$candidate" 2>/dev/null &&
    grep -Fq 'codex wrapper:' "$candidate" 2>/dev/null
}

find_real_codex() {
  local candidate
  local dir
  local old_ifs
  local target="$INSTALL_DIR/codex"

  if [ -n "${CODEX_REAL_BIN:-}" ]; then
    [ -x "$CODEX_REAL_BIN" ] || die "CODEX_REAL_BIN is not executable: $CODEX_REAL_BIN"
    is_managed_wrapper "$CODEX_REAL_BIN" &&
      die "CODEX_REAL_BIN points to the wrapper, not the real Codex executable"
    printf '%s\n' "$CODEX_REAL_BIN"
    return 0
  fi

  old_ifs=$IFS
  IFS=:
  for dir in $PATH; do
    IFS=$old_ifs
    [ -n "$dir" ] || dir=.
    candidate="$dir/codex"
    if [ ! -f "$candidate" ] || [ ! -x "$candidate" ]; then
      IFS=:
      continue
    fi
    if [ -e "$target" ] && [ "$candidate" -ef "$target" ]; then
      IFS=:
      continue
    fi
    if is_managed_wrapper "$candidate"; then
      IFS=:
      continue
    fi
    printf '%s\n' "$candidate"
    IFS=$old_ifs
    return 0
  done
  IFS=$old_ifs
  return 1
}

validate_destination() {
  local target="$INSTALL_DIR/codex"

  case "$INSTALL_DIR" in
    *"'"*|*$'\n'*) die "install directory cannot contain a single quote or newline: $INSTALL_DIR" ;;
  esac

  if { [ -e "$target" ] || [ -L "$target" ]; } && ! is_managed_wrapper "$target"; then
    die "refusing to overwrite $target; set CODEX_WRAPPER_INSTALL_DIR to a different directory"
  fi

  REAL_CODEX_PATH=$(find_real_codex || true)
  [ -n "$REAL_CODEX_PATH" ] ||
    die "real Codex was not found on PATH; install Codex first or set CODEX_REAL_BIN"
}

prompt_yes_no() {
  local prompt=$1
  local answer

  if [ "${CODEX_WRAPPER_YES:-0}" = "1" ]; then
    return 0
  fi

  if [ ! -r /dev/tty ]; then
    return 1
  fi

  while true; do
    printf '%s [Y/n] ' "$prompt" >/dev/tty
    IFS= read -r answer </dev/tty || return 1
    case "$answer" in
      ''|y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) printf 'Please answer y or n.\n' >/dev/tty ;;
    esac
  done
}

find_brew() {
  local candidate

  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi

  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

install_homebrew() {
  prompt_yes_no "Homebrew is required for missing dependencies. Install it now?" ||
    die "install Homebrew from https://brew.sh and rerun this installer"

  if [ "${CODEX_WRAPPER_YES:-0}" = "1" ]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
}

install_dependencies() {
  local os
  local brew_bin
  local packages=()
  local installer=()

  command -v python3 >/dev/null 2>&1 || packages+=(python3)
  command -v tmux >/dev/null 2>&1 || packages+=(tmux)
  [ "${#packages[@]}" -gt 0 ] || return 0

  os=$(uname -s 2>/dev/null || true)
  case "$os" in
    Linux)
      command -v apt-get >/dev/null 2>&1 ||
        die "missing ${packages[*]}; automatic installation currently supports apt-based Linux"
      prompt_yes_no "Install missing dependencies (${packages[*]}) with apt?" ||
        die "install ${packages[*]} and rerun this installer"

      if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        installer=(apt-get)
      else
        command -v sudo >/dev/null 2>&1 ||
          die "sudo is required to install ${packages[*]}"
        installer=(sudo apt-get)
      fi

      "${installer[@]}" update
      if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      else
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      fi
      ;;
    Darwin)
      brew_bin=$(find_brew || true)
      if [ -z "$brew_bin" ]; then
        install_homebrew
        brew_bin=$(find_brew || true)
      fi
      [ -n "$brew_bin" ] || die "Homebrew installation did not provide a brew executable"

      packages=()
      command -v python3 >/dev/null 2>&1 || packages+=(python)
      command -v tmux >/dev/null 2>&1 || packages+=(tmux)
      if [ "${#packages[@]}" -gt 0 ]; then
        prompt_yes_no "Install missing dependencies (${packages[*]}) with Homebrew?" ||
          die "install ${packages[*]} and rerun this installer"
        "$brew_bin" install "${packages[@]}"
      fi

      eval "$("$brew_bin" shellenv)"
      ;;
    *)
      die "unsupported operating system: ${os:-unknown}"
      ;;
  esac

  command -v python3 >/dev/null 2>&1 || die "python3 is still unavailable"
  command -v tmux >/dev/null 2>&1 || die "tmux is still unavailable"
}

download_wrapper() {
  local archive
  local python_bin
  local source_dir
  local temp_dir

  command -v curl >/dev/null 2>&1 || die "curl is required"
  python_bin=$(command -v python3)
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' EXIT
  archive="$temp_dir/source.tar.gz"
  source_dir="$temp_dir/source"

  curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${REF}" -o "$archive"
  mkdir -p "$source_dir"
  tar -xzf "$archive" -C "$source_dir" --strip-components=1
  [ -f "$source_dir/codex" ] || die "downloaded snapshot does not contain codex"
  [ -f "$source_dir/codex-watch" ] || die "downloaded snapshot does not contain codex-watch"

  {
    printf '#!%s\n' "$python_bin"
    tail -n +2 "$source_dir/codex-watch"
  } >"$temp_dir/codex-watch"

  mkdir -p "$INSTALL_DIR"
  install -m 755 "$source_dir/codex" "$INSTALL_DIR/codex"
  install -m 755 "$temp_dir/codex-watch" "$INSTALL_DIR/codex-watch"

  rm -rf "$temp_dir"
  trap - EXIT
}

DETECTED_SHELLS=()

add_shell() {
  local shell_name=$1
  local existing

  if [ "${#DETECTED_SHELLS[@]}" -gt 0 ]; then
    for existing in "${DETECTED_SHELLS[@]}"; do
      [ "$existing" = "$shell_name" ] && return 0
    done
  fi
  DETECTED_SHELLS+=("$shell_name")
}

detect_shells() {
  local login_shell

  login_shell=$(basename "${SHELL:-}")
  case "$login_shell" in
    bash|zsh|fish) add_shell "$login_shell" ;;
  esac

  [ -f "$HOME/.bashrc" ] && add_shell bash
  [ -f "$HOME/.bash_profile" ] && add_shell bash
  [ -f "$HOME/.bash_login" ] && add_shell bash
  [ -f "$HOME/.profile" ] && add_shell bash
  [ -f "${ZDOTDIR:-$HOME}/.zshrc" ] && add_shell zsh
  [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ] && add_shell fish

  if [ "${#DETECTED_SHELLS[@]}" -eq 0 ]; then
    case "$(uname -s 2>/dev/null || true)" in
      Darwin) add_shell zsh ;;
      *) add_shell bash ;;
    esac
  fi
}

managed_block_present() {
  local config_file=$1
  local start_marker=$2
  local end_marker=$3

  [ -f "$config_file" ] || return 1
  if ! grep -Fqx "$start_marker" "$config_file" &&
     ! grep -Fqx "$end_marker" "$config_file"; then
    return 1
  fi

  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start {
      starts++
      if (active) bad = 1
      active = 1
      next
    }
    $0 == end {
      ends++
      if (!active) bad = 1
      active = 0
      next
    }
    END {
      if (bad || active || starts != 1 || ends != 1) exit 1
    }
  ' "$config_file" ||
    die "malformed managed block in $config_file; refusing to modify it"
  return 0
}

write_alias_block() {
  local alias_line=$1
  local config_file=$2
  local line
  local skipping=0
  local temp_file

  if managed_block_present "$config_file" "$MARKER_START" "$MARKER_END"; then
    temp_file=$(mktemp "${config_file}.tmp.XXXXXX")
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$MARKER_START" ]; then
        printf '%s\n%s\n%s\n' "$MARKER_START" "$alias_line" "$MARKER_END" >>"$temp_file"
        skipping=1
      elif [ "$line" = "$MARKER_END" ]; then
        skipping=0
      elif [ "$skipping" -eq 0 ]; then
        printf '%s\n' "$line" >>"$temp_file"
      fi
    done <"$config_file"
    command cat "$temp_file" >"$config_file"
    rm -f "$temp_file"
  else
    if [ -s "$config_file" ]; then
      printf '\n' >>"$config_file"
    fi
    {
      printf '%s\n%s\n%s\n' "$MARKER_START" "$alias_line" "$MARKER_END"
    } >>"$config_file"
  fi
}

configure_alias_file() {
  local shell_name=$1
  local config_file=$2
  local alias_line

  mkdir -p "$(dirname "$config_file")"
  touch "$config_file"

  case "$shell_name" in
    bash|zsh) alias_line="alias codex='$INSTALL_DIR/codex'" ;;
    fish) alias_line="alias codex '$INSTALL_DIR/codex'" ;;
    *) return 0 ;;
  esac

  write_alias_block "$alias_line" "$config_file"
  say "configured $shell_name alias in $config_file"
}

configure_alias() {
  local shell_name=$1
  local login_config=""

  case "$shell_name" in
    bash)
      if [ -f "$HOME/.bash_profile" ]; then
        login_config="$HOME/.bash_profile"
      elif [ -f "$HOME/.bash_login" ]; then
        login_config="$HOME/.bash_login"
      elif [ -f "$HOME/.profile" ]; then
        login_config="$HOME/.profile"
      elif [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
        login_config="$HOME/.bash_profile"
      fi

      managed_block_present "$HOME/.bashrc" "$MARKER_START" "$MARKER_END" || true
      if [ -n "$login_config" ]; then
        managed_block_present "$login_config" "$MARKER_START" "$MARKER_END" || true
      fi
      configure_alias_file bash "$HOME/.bashrc"
      if [ -n "$login_config" ] && [ "$login_config" != "$HOME/.bashrc" ]; then
        configure_alias_file bash "$login_config"
      fi
      ;;
    zsh)
      configure_alias_file zsh "${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    fish)
      configure_alias_file fish "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
      ;;
  esac
}

print_keymap_snippet() {
  printf '%s\n' \
    '[tui.keymap.composer]' \
    'submit = ["enter", "ctrl-m"]' \
    '' \
    '[tui.keymap.editor]' \
    'insert_newline = ["ctrl-j", "shift-enter", "alt-enter"]'
}

inspect_codex_keymap() {
  local config_file=$1

  python3 - "$config_file" <<'PY'
import pathlib
import sys

try:
    import tomllib
except ImportError:
    raise SystemExit(3)

try:
    data = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception:
    raise SystemExit(4)

tui = data.get("tui", {})
keymap = tui.get("keymap", {}) if isinstance(tui, dict) else {}
composer = keymap.get("composer", {}) if isinstance(keymap, dict) else {}
editor = keymap.get("editor", {}) if isinstance(keymap, dict) else {}
submit = composer.get("submit", []) if isinstance(composer, dict) else []
newlines = editor.get("insert_newline", []) if isinstance(editor, dict) else []

if isinstance(submit, list) and "ctrl-m" in submit:
    if not isinstance(newlines, list) or "ctrl-m" not in newlines:
        raise SystemExit(5)

if composer or editor:
    raise SystemExit(2)
raise SystemExit(0)
PY
}

write_keymap_block() {
  local config_file=$1
  local line
  local skipping=0
  local temp_file

  if managed_block_present "$config_file" "$KEYMAP_MARKER_START" "$KEYMAP_MARKER_END"; then
    temp_file=$(mktemp "${config_file}.tmp.XXXXXX")
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$KEYMAP_MARKER_START" ]; then
        {
          printf '%s\n' "$KEYMAP_MARKER_START"
          print_keymap_snippet
          printf '%s\n' "$KEYMAP_MARKER_END"
        } >>"$temp_file"
        skipping=1
      elif [ "$line" = "$KEYMAP_MARKER_END" ]; then
        skipping=0
      elif [ "$skipping" -eq 0 ]; then
        printf '%s\n' "$line" >>"$temp_file"
      fi
    done <"$config_file"
    command cat "$temp_file" >"$config_file"
    rm -f "$temp_file"
  else
    if [ -s "$config_file" ]; then
      printf '\n' >>"$config_file"
    fi
    {
      printf '%s\n' "$KEYMAP_MARKER_START"
      print_keymap_snippet
      printf '%s\n' "$KEYMAP_MARKER_END"
    } >>"$config_file"
  fi
}

validate_codex_config() {
  local codex_dir=$1

  CODEX_HOME="$codex_dir" "$REAL_CODEX_PATH" --version >/dev/null 2>&1
}

configure_codex_keymap() {
  local codex_dir=${CODEX_HOME:-"$HOME/.codex"}
  local config_file="$codex_dir/config.toml"
  local config_existed=0
  local inspect_status=0
  local temp_backup

  mkdir -p "$codex_dir"
  [ -e "$config_file" ] && config_existed=1
  touch "$config_file"

  if managed_block_present "$config_file" "$KEYMAP_MARKER_START" "$KEYMAP_MARKER_END"; then
    inspect_status=2
  else
    if inspect_codex_keymap "$config_file"; then
      inspect_status=0
    else
      inspect_status=$?
    fi

    case "$inspect_status" in
      5)
        say "Codex Ctrl-M keymap is already configured in $config_file"
        return 0
        ;;
      2)
        ;;
      3)
        if grep -Eq '^([[:space:]]*\[tui\.keymap\.(composer|editor)\]|[[:space:]]*tui\.keymap\.(composer|editor)\.)' "$config_file"; then
          inspect_status=2
        else
          inspect_status=0
        fi
        ;;
      4)
        say "existing Codex config is not valid TOML: $config_file"
        return 1
        ;;
    esac
  fi

  if [ "$inspect_status" -eq 0 ] &&
     grep -Eq "^[[:space:]]*['\"]?tui['\"]?[[:space:]]*(=|\.)" "$config_file"; then
    inspect_status=2
  fi

  if [ "$inspect_status" -eq 2 ] &&
     ! managed_block_present "$config_file" "$KEYMAP_MARKER_START" "$KEYMAP_MARKER_END"; then
    say "existing Codex composer/editor keymap found in $config_file"
    say "not changing it automatically because duplicate TOML tables would break Codex"
    printf '\nAdd or merge these values manually:\n' >&2
    print_keymap_snippet >&2
    printf '\n' >&2
    return 1
  fi

  temp_backup=$(mktemp "${config_file}.backup.XXXXXX")
  command cat "$config_file" >"$temp_backup"
  write_keymap_block "$config_file"

  if ! validate_codex_config "$codex_dir"; then
    if [ "$config_existed" -eq 1 ]; then
      command cat "$temp_backup" >"$config_file"
    else
      rm -f "$config_file"
    fi
    rm -f "$temp_backup"
    say "Codex rejected the generated config; restored the original config"
    return 1
  fi
  rm -f "$temp_backup"

  say "configured the Ctrl-M keymap in $config_file"
}

main() {
  local shell_name
  local shell_list=""

  say "installing from https://github.com/$REPO"
  validate_destination
  install_dependencies
  download_wrapper

  bash -n "$INSTALL_DIR/codex"
  python3 "$INSTALL_DIR/codex-watch" --help >/dev/null
  say "installed codex and codex-watch in $INSTALL_DIR"

  say "Ctrl-M submit lets the watcher submit /goal resume and activate Keep waiting."
  say "Without it, Codex may only insert a newline or leave the automatic reply unsubmitted."
  if prompt_yes_no "Append the required Ctrl-M keymap to the Codex config?"; then
    configure_codex_keymap ||
      die "keymap setup failed; merge the displayed values and rerun the installer"
  else
    say "keymap not changed; automatic replies may not be submitted"
  fi

  detect_shells
  for shell_name in "${DETECTED_SHELLS[@]}"; do
    if [ -n "$shell_list" ]; then
      shell_list="$shell_list, $shell_name"
    else
      shell_list=$shell_name
    fi
  done

  if prompt_yes_no "Override the interactive codex command with the wrapper alias for: $shell_list?"; then
    for shell_name in "${DETECTED_SHELLS[@]}"; do
      configure_alias "$shell_name"
    done
    say "open a new shell (or source its config) before running codex"
  else
    say "alias not changed; run the wrapper directly as $INSTALL_DIR/codex"
  fi

  say "installation complete; real Codex: $REAL_CODEX_PATH"
}

main "$@"
