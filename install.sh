#!/usr/bin/env bash
set -euo pipefail

REPO="wktkow/codex-antibug-shit-wrapper"
REF=${CODEX_WRAPPER_REF:-main}
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
INSTALL_DIR=${CODEX_WRAPPER_INSTALL_DIR:-"$HOME/.local/bin"}
MARKER_START="# >>> codex-antifreeze-shit-wrapper >>>"
MARKER_END="# <<< codex-antifreeze-shit-wrapper <<<"

say() {
  printf 'codex wrapper installer: %s\n' "$*"
}

die() {
  printf 'codex wrapper installer: %s\n' "$*" >&2
  exit 1
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

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
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
  local python_bin
  local temp_dir

  command -v curl >/dev/null 2>&1 || die "curl is required"
  python_bin=$(command -v python3)
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' EXIT

  curl -fsSL "$RAW_BASE/codex" -o "$temp_dir/codex"
  curl -fsSL "$RAW_BASE/codex-watch" -o "$temp_dir/codex-watch"

  {
    printf '#!%s\n' "$python_bin"
    tail -n +2 "$temp_dir/codex-watch"
  } >"$temp_dir/codex-watch.configured"
  mv "$temp_dir/codex-watch.configured" "$temp_dir/codex-watch"

  mkdir -p "$INSTALL_DIR"
  install -m 755 "$temp_dir/codex" "$INSTALL_DIR/codex"
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
  [ -f "$HOME/.zshrc" ] && add_shell zsh
  [ -f "$HOME/.config/fish/config.fish" ] && add_shell fish

  if [ "${#DETECTED_SHELLS[@]}" -eq 0 ]; then
    case "$(uname -s 2>/dev/null || true)" in
      Darwin) add_shell zsh ;;
      *) add_shell bash ;;
    esac
  fi
}

shell_config_path() {
  case "$1" in
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    zsh) printf '%s\n' "$HOME/.zshrc" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    *) return 1 ;;
  esac
}

remove_managed_alias() {
  local config_file=$1
  local temp_file

  [ -f "$config_file" ] || return 0
  grep -Fqx "$MARKER_START" "$config_file" || return 0

  temp_file=$(mktemp "${config_file}.tmp.XXXXXX")
  awk -v start="$MARKER_START" -v end="$MARKER_END" '
    $0 == start { skipping = 1; next }
    $0 == end { skipping = 0; next }
    !skipping { print }
  ' "$config_file" >"$temp_file"
  command cat "$temp_file" >"$config_file"
  rm -f "$temp_file"
}

configure_alias() {
  local shell_name=$1
  local config_file
  local alias_line

  config_file=$(shell_config_path "$shell_name")
  mkdir -p "$(dirname "$config_file")"
  touch "$config_file"
  remove_managed_alias "$config_file"

  case "$shell_name" in
    bash|zsh) alias_line="alias codex=\"$INSTALL_DIR/codex\"" ;;
    fish) alias_line="alias codex \"$INSTALL_DIR/codex\"" ;;
    *) return 0 ;;
  esac

  {
    printf '\n%s\n' "$MARKER_START"
    printf '%s\n' "$alias_line"
    printf '%s\n' "$MARKER_END"
  } >>"$config_file"

  say "configured $shell_name alias in $config_file"
}

main() {
  local shell_name
  local shell_list=""

  say "installing from https://github.com/$REPO"
  install_dependencies
  download_wrapper

  bash -n "$INSTALL_DIR/codex"
  python3 "$INSTALL_DIR/codex-watch" --help >/dev/null
  say "installed codex and codex-watch in $INSTALL_DIR"

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

  if ! command -v codex >/dev/null 2>&1; then
    say "warning: the real Codex executable was not found on PATH"
  fi

  say "installation complete"
}

main "$@"
