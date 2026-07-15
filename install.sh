#!/usr/bin/env bash
set -euo pipefail

REPO="wktkow/codex-antifreeze-wrapper"
REF=${CODEX_WRAPPER_REF:-main}
INSTALL_DIR=${CODEX_WRAPPER_INSTALL_DIR:-"$HOME/.local/bin"}
MARKER_START="# >>> codex-antifreeze-wrapper >>>"
MARKER_END="# <<< codex-antifreeze-wrapper <<<"
LEGACY_MARKER_START="# >>> codex-antifreeze-shit-wrapper >>>"
LEGACY_MARKER_END="# <<< codex-antifreeze-shit-wrapper <<<"
KEYMAP_MARKER_START="# >>> codex-antifreeze keymap >>>"
KEYMAP_MARKER_END="# <<< codex-antifreeze keymap <<<"
REAL_CODEX_PATH=""
INSTALL_ACTION="installed"

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
  grep -Fq 'codex-antifreeze-wrapper managed executable' "$candidate" 2>/dev/null &&
    return 0
  grep -Fq 'codex-antifreeze-shit-wrapper managed executable' "$candidate" 2>/dev/null &&
    return 0
  grep -Fq 'find_real_codex()' "$candidate" 2>/dev/null &&
    grep -Fq 'codex wrapper:' "$candidate" 2>/dev/null
}

is_managed_watcher() {
  local candidate=$1

  [ -f "$candidate" ] || return 1
  grep -Fq 'codex-antifreeze-wrapper managed watcher' "$candidate" 2>/dev/null &&
    return 0
  # Recognize every watcher version published before the marker was added.
  grep -Fq 'TYPE_IN =' "$candidate" 2>/dev/null &&
    grep -Fq 'WHEN_OUTPUT_CONTAINS =' "$candidate" 2>/dev/null &&
    grep -Fq 'pty.fork()' "$candidate" 2>/dev/null &&
    grep -Fq 'codex-watch:' "$candidate" 2>/dev/null
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
  local watcher="$INSTALL_DIR/codex-watch"

  case "$INSTALL_DIR" in
    *"'"*|*$'\n'*) die "install directory cannot contain a single quote or newline: $INSTALL_DIR" ;;
  esac

  if [ -e "$target" ] || [ -L "$target" ]; then
    is_managed_wrapper "$target" ||
      die "refusing to overwrite $target; set CODEX_WRAPPER_INSTALL_DIR to a different directory"
  fi

  if [ -e "$watcher" ] || [ -L "$watcher" ]; then
    if { [ ! -f "$watcher" ] && [ ! -L "$watcher" ]; } || [ -d "$watcher" ]; then
      die "refusing to overwrite non-file destination $watcher"
    fi
    if ! is_managed_watcher "$watcher"; then
      die "refusing to overwrite unrelated executable $watcher"
    fi
  fi

  if [ -e "$target" ] || [ -L "$target" ] ||
     [ -e "$watcher" ] || [ -L "$watcher" ]; then
    INSTALL_ACTION="updated"
  fi
  if [ "$INSTALL_ACTION" = "installed" ] && managed_configuration_present; then
    INSTALL_ACTION="updated"
  fi

  REAL_CODEX_PATH=$(find_real_codex || true)
  [ -n "$REAL_CODEX_PATH" ] ||
    die "real Codex was not found on PATH; install Codex first or set CODEX_REAL_BIN"
}

replace_wrappers() {
  local stage_dir=$1
  local target="$INSTALL_DIR/codex"
  local watcher="$INSTALL_DIR/codex-watch"
  local target_existed=0

  if [ -e "$target" ] || [ -L "$target" ]; then
    target_existed=1
    cp -pP "$target" "$stage_dir/codex.previous"
  fi

  mv -f "$stage_dir/codex" "$target"
  if ! mv -f "$stage_dir/codex-watch" "$watcher"; then
    if [ "$target_existed" -eq 1 ]; then
      if ! mv -f "$stage_dir/codex.previous" "$target"; then
        trap - EXIT
        die "watcher update failed and the previous wrapper could not be restored; backup: $stage_dir/codex.previous"
      fi
    else
      rm -f "$target"
    fi
    die "watcher update failed; restored the previous wrapper"
  fi

  rm -f "$stage_dir/codex.previous"
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
  local stage_dir=""
  local temp_dir

  command -v curl >/dev/null 2>&1 || die "curl is required"
  python_bin=$(command -v python3)
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"; [ -z "${stage_dir:-}" ] || rm -rf "$stage_dir"' EXIT
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

  bash -n "$source_dir/codex"
  "$python_bin" "$temp_dir/codex-watch" --help >/dev/null

  mkdir -p "$INSTALL_DIR"
  stage_dir=$(mktemp -d "$INSTALL_DIR/.codex-wrapper-install.XXXXXX")
  # Always replace both managed executables. This makes a rerun an update and
  # avoids leaving an older watcher paired with a newer wrapper (or vice versa).
  install -m 755 "$source_dir/codex" "$stage_dir/codex"
  install -m 755 "$temp_dir/codex-watch" "$stage_dir/codex-watch"
  replace_wrappers "$stage_dir"

  rm -rf "$temp_dir" "$stage_dir"
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

alias_managed_block_present() {
  local config_file=$1
  local has_block=0

  [ -f "$config_file" ] || return 1
  if managed_block_present "$config_file" "$MARKER_START" "$MARKER_END"; then
    has_block=1
  fi
  if managed_block_present "$config_file" "$LEGACY_MARKER_START" "$LEGACY_MARKER_END"; then
    has_block=1
  fi
  [ "$has_block" -eq 1 ] || return 1

  awk -v new_start="$MARKER_START" -v new_end="$MARKER_END" \
      -v legacy_start="$LEGACY_MARKER_START" -v legacy_end="$LEGACY_MARKER_END" '
    $0 == new_start || $0 == legacy_start {
      starts++
      if (active) bad = 1
      active = 1
      next
    }
    $0 == new_end || $0 == legacy_end {
      ends++
      if (!active) bad = 1
      active = 0
      next
    }
    END {
      if (bad || active || starts != ends) exit 1
    }
  ' "$config_file" ||
    die "overlapping managed alias blocks in $config_file; refusing to modify it"
}

preflight_managed_configs() {
  local config_file="${CODEX_HOME:-$HOME/.codex}/config.toml"

  managed_block_present "$config_file" "$KEYMAP_MARKER_START" "$KEYMAP_MARKER_END" || true
  alias_managed_block_present "$HOME/.bashrc" || true
  alias_managed_block_present "$HOME/.bash_profile" || true
  alias_managed_block_present "$HOME/.bash_login" || true
  alias_managed_block_present "$HOME/.profile" || true
  alias_managed_block_present "${ZDOTDIR:-$HOME}/.zshrc" || true
  alias_managed_block_present \
    "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" || true
}

managed_configuration_present() {
  local config_file="${CODEX_HOME:-$HOME/.codex}/config.toml"

  managed_block_present "$config_file" "$KEYMAP_MARKER_START" "$KEYMAP_MARKER_END" &&
    return 0
  alias_managed_block_present "$HOME/.bashrc" && return 0
  alias_managed_block_present "$HOME/.bash_profile" && return 0
  alias_managed_block_present "$HOME/.bash_login" && return 0
  alias_managed_block_present "$HOME/.profile" && return 0
  alias_managed_block_present "${ZDOTDIR:-$HOME}/.zshrc" && return 0
  alias_managed_block_present \
    "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" && return 0
  return 1
}

write_alias_block() {
  local alias_line=$1
  local config_file=$2
  local line
  local legacy_present=0
  local new_present=0
  local skipping=0
  local temp_file
  local wrote_block=0

  if managed_block_present "$config_file" "$MARKER_START" "$MARKER_END"; then
    new_present=1
  fi
  if managed_block_present "$config_file" "$LEGACY_MARKER_START" "$LEGACY_MARKER_END"; then
    legacy_present=1
  fi

  if [ "$new_present" -eq 1 ] || [ "$legacy_present" -eq 1 ]; then
    temp_file=$(mktemp "${config_file}.tmp.XXXXXX")
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$MARKER_START" ] || [ "$line" = "$LEGACY_MARKER_START" ]; then
        if [ "$wrote_block" -eq 0 ]; then
          printf '%s\n%s\n%s\n' "$MARKER_START" "$alias_line" "$MARKER_END" >>"$temp_file"
          wrote_block=1
        fi
        skipping=1
      elif [ "$line" = "$MARKER_END" ] || [ "$line" = "$LEGACY_MARKER_END" ]; then
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

bash_login_config() {
  if [ -f "$HOME/.bash_profile" ]; then
    printf '%s\n' "$HOME/.bash_profile"
  elif [ -f "$HOME/.bash_login" ]; then
    printf '%s\n' "$HOME/.bash_login"
  elif [ -f "$HOME/.profile" ]; then
    printf '%s\n' "$HOME/.profile"
  elif [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]; then
    printf '%s\n' "$HOME/.bash_profile"
  fi
}

configure_alias() {
  local shell_name=$1
  local login_config=""

  case "$shell_name" in
    bash)
      login_config=$(bash_login_config)

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

CONFIGURED_ALIAS_FILES=()
REFRESHED_MANAGED_ALIAS_FILES=0
EXISTING_MANUAL_ALIAS_FILES=0

add_configured_alias_file() {
  local config_file=$1
  local existing

  if [ "${#CONFIGURED_ALIAS_FILES[@]}" -gt 0 ]; then
    for existing in "${CONFIGURED_ALIAS_FILES[@]}"; do
      [ "$existing" = "$config_file" ] && return 0
    done
  fi
  CONFIGURED_ALIAS_FILES+=("$config_file")
}

configured_alias_file_present() {
  local config_file=$1
  local existing

  if [ "${#CONFIGURED_ALIAS_FILES[@]}" -gt 0 ]; then
    for existing in "${CONFIGURED_ALIAS_FILES[@]}"; do
      [ "$existing" = "$config_file" ] && return 0
    done
  fi
  return 1
}

shell_alias_fully_configured() {
  local shell_name=$1
  local login_config=""

  case "$shell_name" in
    bash)
      configured_alias_file_present "$HOME/.bashrc" || return 1
      login_config=$(bash_login_config)
      [ -z "$login_config" ] || configured_alias_file_present "$login_config"
      ;;
    zsh)
      configured_alias_file_present "${ZDOTDIR:-$HOME}/.zshrc"
      ;;
    fish)
      configured_alias_file_present \
        "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
      ;;
    *) return 1 ;;
  esac
}

install_dir_is_unquoted_shell_safe() {
  case "$INSTALL_DIR" in
    *[!A-Za-z0-9_./-]*) return 1 ;;
    *) return 0 ;;
  esac
}

alias_file_already_configured() {
  local shell_name=$1
  local config_file=$2

  [ -f "$config_file" ] || return 1
  case "$shell_name" in
    bash|zsh)
      grep -Fqx "alias codex='$INSTALL_DIR/codex'" "$config_file" || {
        install_dir_is_unquoted_shell_safe && {
          grep -Fqx "alias codex=\"$INSTALL_DIR/codex\"" "$config_file" ||
            grep -Fqx "alias codex=$INSTALL_DIR/codex" "$config_file"
        }
      }
      ;;
    fish)
      grep -Fqx "alias codex '$INSTALL_DIR/codex'" "$config_file" || {
        install_dir_is_unquoted_shell_safe &&
          grep -Fqx "alias codex \"$INSTALL_DIR/codex\"" "$config_file"
      }
      ;;
    *) return 1 ;;
  esac
}

refresh_managed_alias_file() {
  local shell_name=$1
  local config_file=$2

  [ -f "$config_file" ] || return 0
  if alias_managed_block_present "$config_file"; then
    configure_alias_file "$shell_name" "$config_file"
    add_configured_alias_file "$config_file"
    REFRESHED_MANAGED_ALIAS_FILES=$((REFRESHED_MANAGED_ALIAS_FILES + 1))
  elif alias_file_already_configured "$shell_name" "$config_file"; then
    say "existing $shell_name alias found in $config_file; leaving it unchanged"
    add_configured_alias_file "$config_file"
    EXISTING_MANUAL_ALIAS_FILES=$((EXISTING_MANUAL_ALIAS_FILES + 1))
  fi
}

refresh_managed_aliases() {
  CONFIGURED_ALIAS_FILES=()
  REFRESHED_MANAGED_ALIAS_FILES=0
  EXISTING_MANUAL_ALIAS_FILES=0

  refresh_managed_alias_file bash "$HOME/.bashrc"
  refresh_managed_alias_file bash "$HOME/.bash_profile"
  refresh_managed_alias_file bash "$HOME/.bash_login"
  refresh_managed_alias_file bash "$HOME/.profile"
  refresh_managed_alias_file zsh "${ZDOTDIR:-$HOME}/.zshrc"
  refresh_managed_alias_file fish \
    "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
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
composer_present = isinstance(keymap, dict) and "composer" in keymap
editor_present = isinstance(keymap, dict) and "editor" in keymap
composer = keymap.get("composer", {}) if isinstance(keymap, dict) else {}
editor = keymap.get("editor", {}) if isinstance(keymap, dict) else {}
submit = composer.get("submit", []) if isinstance(composer, dict) else []
newlines = editor.get("insert_newline", []) if isinstance(editor, dict) else []

if isinstance(submit, list) and "ctrl-m" in submit:
    if not isinstance(newlines, list) or "ctrl-m" not in newlines:
        raise SystemExit(5)

if composer_present or editor_present:
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

classify_codex_keymap() {
  local codex_dir=${CODEX_HOME:-"$HOME/.codex"}
  local config_file="$codex_dir/config.toml"
  local inspect_status=0

  if [ ! -f "$config_file" ]; then
    printf '%s\n' absent
    return 0
  fi

  if inspect_codex_keymap "$config_file"; then
    printf '%s\n' absent
    return 0
  else
    inspect_status=$?
  fi

  case "$inspect_status" in
    2) printf '%s\n' conflict ;;
    4) printf '%s\n' invalid ;;
    5) printf '%s\n' compatible ;;
    3)
      if grep -Eq '^([[:space:]]*\[tui\.keymap\.(composer|editor)\]|[[:space:]]*tui\.keymap\.(composer|editor)\.)' \
           "$config_file" ||
         grep -Eq "^[[:space:]]*['\"]?tui['\"]?[[:space:]]*(=|\.)" "$config_file"; then
        printf '%s\n' conflict
      else
        printf '%s\n' absent
      fi
      ;;
    *) printf '%s\n' absent ;;
  esac
}

main() {
  local codex_dir=${CODEX_HOME:-"$HOME/.codex"}
  local config_file="$codex_dir/config.toml"
  local keymap_state=""
  local missing_shells=()
  local shell_name
  local shell_list=""

  say "installing from https://github.com/$REPO"
  preflight_managed_configs
  validate_destination
  install_dependencies
  download_wrapper

  bash -n "$INSTALL_DIR/codex"
  python3 "$INSTALL_DIR/codex-watch" --help >/dev/null
  say "$INSTALL_ACTION codex and codex-watch in $INSTALL_DIR"
  if [ "$INSTALL_ACTION" = "updated" ]; then
    say "restart existing Codex tmux sessions to load the updated watcher"
  fi

  if managed_block_present "$config_file" "$KEYMAP_MARKER_START" "$KEYMAP_MARKER_END"; then
    say "refreshing the existing installer-managed Ctrl-M keymap"
    configure_codex_keymap ||
      die "keymap setup failed; merge the displayed values and rerun the installer"
  else
    keymap_state=$(classify_codex_keymap)
    case "$keymap_state" in
      compatible)
        say "compatible Codex Ctrl-M keymap found in $config_file; leaving it unchanged"
        ;;
      conflict)
        say "existing Codex composer/editor keymap found in $config_file"
        say "leaving it unchanged; merge these values manually to enable automatic replies:"
        print_keymap_snippet >&2
        ;;
      invalid)
        say "existing Codex config is not valid TOML: $config_file"
        say "leaving it unchanged; fix the config before adding the Ctrl-M keymap"
        ;;
      absent)
        if [ "$INSTALL_ACTION" = "updated" ]; then
          say "no installer-managed Codex keymap found; leaving the config unchanged"
        else
          say "Ctrl-M submit lets the watcher submit /goal resume; arrow keys and Return activate Keep waiting."
          say "Without it, Codex may only insert a newline or leave the automatic reply unsubmitted."
          if prompt_yes_no "Append the required Ctrl-M keymap to the Codex config?"; then
            configure_codex_keymap ||
              die "keymap setup failed; merge the displayed values and rerun the installer"
          else
            say "keymap not changed; automatic replies may not be submitted"
          fi
        fi
        ;;
    esac
  fi

  refresh_managed_aliases
  detect_shells
  for shell_name in "${DETECTED_SHELLS[@]}"; do
    if ! shell_alias_fully_configured "$shell_name"; then
      missing_shells+=("$shell_name")
    fi
  done

  if [ "$REFRESHED_MANAGED_ALIAS_FILES" -gt 0 ]; then
    say "refreshed existing installer-managed shell aliases"
  fi
  if [ "$EXISTING_MANUAL_ALIAS_FILES" -gt 0 ]; then
    say "equivalent existing shell aliases were left unchanged"
  fi

  if [ "${#missing_shells[@]}" -eq 0 ]; then
    say "all detected shell aliases are already configured; no alias prompt needed"
  elif [ "$INSTALL_ACTION" = "updated" ]; then
    say "leaving shell configs without installer-managed aliases unchanged"
  else
    for shell_name in "${missing_shells[@]}"; do
      if [ -n "$shell_list" ]; then
        shell_list="$shell_list, $shell_name"
      else
        shell_list=$shell_name
      fi
    done

    if prompt_yes_no "Override the interactive codex command with the wrapper alias for: $shell_list?"; then
      for shell_name in "${missing_shells[@]}"; do
        configure_alias "$shell_name"
      done
      say "open a new shell (or source its config) before running codex"
    else
      say "aliases not added; run the wrapper directly as $INSTALL_DIR/codex"
    fi
  fi

  say "installation complete; real Codex: $REAL_CODEX_PATH"
}

main "$@"
