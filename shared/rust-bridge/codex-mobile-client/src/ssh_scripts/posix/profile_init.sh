# Import the login environment into the POSIX shell used by Litter's SSH
# commands. The command executor remains `/usr/bin/env sh`; a user's fish or
# zsh configuration is only consulted for PATH discovery and never asked to
# interpret Litter's generated scripts.
_litter_path_prepend() {
  [ -n "$1" ] || return 0
  case ":${PATH:-}:" in
    *":$1:"*) ;;
    *) [ -d "$1" ] && PATH="$1${PATH:+:$PATH}" ;;
  esac
}

_litter_import_posix_profile() {
  [ -f "$1" ] || return 0
  _litter_candidate_path="$(
    (
      # Profiles belong to the remote user and may contain shell-specific
      # syntax. Keep failures and side effects inside this subshell.
      # shellcheck disable=SC1090
      . "$1" >/dev/null 2>&1
      printf '%s\n' "${PATH:-}"
    ) 2>/dev/null | tail -n 1
  )"
  [ -n "$_litter_candidate_path" ] && PATH="$_litter_candidate_path"
}

for _litter_profile in \
  "$HOME/.zshenv" \
  "$HOME/.profile" \
  "$HOME/.bash_profile" \
  "$HOME/.bashrc" \
  "$HOME/.zprofile" \
  "$HOME/.zshrc"
do
  _litter_import_posix_profile "$_litter_profile"
done

# NixOS and `nix profile` installs commonly place user and system programs in
# these directories without mentioning them in a POSIX profile.
_litter_add_nix_paths() {
  _litter_path_prepend "$HOME/.nix-profile/bin"
  _litter_path_prepend "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profile/bin"
  [ -n "${USER:-}" ] && _litter_path_prepend "/etc/profiles/per-user/$USER/bin"
  _litter_path_prepend "/nix/var/nix/profiles/default/bin"
  _litter_path_prepend "/run/current-system/sw/bin"
  _litter_path_prepend "/run/wrappers/bin"
}
_litter_add_nix_paths

# Fish configuration cannot be sourced by sh. When fish is the account's
# selected login shell, start it only long enough to read its normal startup
# files and emit its exported PATH between sentinels. Config-file chatter is
# ignored, and Litter's generated commands continue to execute under sh.
_litter_login_shell="${SHELL:-}"
case "$_litter_login_shell" in
  fish)
    _litter_login_shell="$(command -v fish 2>/dev/null || true)"
    ;;
esac
case "$_litter_login_shell" in
  */fish)
    if [ -x "$_litter_login_shell" ]; then
      _litter_fish_path="$(
        "$_litter_login_shell" --login --command \
          'printf "__litter_path_start__%s__litter_path_end__\n" "$PATH"' \
          2>/dev/null |
          sed -n 's/^__litter_path_start__\(.*\)__litter_path_end__$/\1/p' |
          tail -n 1
      )"
      [ -n "$_litter_fish_path" ] && PATH="$_litter_fish_path"
    fi
    ;;
esac

# A fish config can replace PATH rather than extend it. Restore any existing
# Nix profile directories without duplicating entries.
_litter_add_nix_paths

_litter_path_prepend "$NVM_BIN"
_litter_path_prepend "${ASDF_DATA_DIR:-}/shims"
_litter_path_prepend "/opt/homebrew/opt/node/bin"
_litter_path_prepend "/opt/homebrew/bin"
_litter_path_prepend "/usr/local/opt/node/bin"
_litter_path_prepend "/usr/local/bin"
_litter_path_prepend "$HOME/.volta/bin"
_litter_path_prepend "$HOME/.bun/bin"
_litter_path_prepend "$HOME/.local/bin"
_litter_path_prepend "${CARGO_HOME:-$HOME/.cargo}/bin"
_litter_path_prepend "${PNPM_HOME:-$HOME/Library/pnpm}"
_litter_path_prepend "$HOME/.opencode/bin"

_litter_nvm_dir="${NVM_DIR:-$HOME/.nvm}"
if [ -d "$_litter_nvm_dir/versions/node" ]; then
  _litter_nvm_default=""
  if [ -f "$_litter_nvm_dir/alias/default" ]; then
    _litter_nvm_default="$(cat "$_litter_nvm_dir/alias/default" 2>/dev/null || true)"
  fi
  if [ -n "$_litter_nvm_default" ]; then
    _litter_path_prepend "$_litter_nvm_dir/versions/node/$_litter_nvm_default/bin"
  fi
  for _litter_node_bin in "$_litter_nvm_dir"/versions/node/*/bin; do
    [ -x "$_litter_node_bin/node" ] && _litter_path_prepend "$_litter_node_bin"
  done
fi
if [ -d "$HOME/.fnm/node-versions" ]; then
  for _litter_node_bin in "$HOME"/.fnm/node-versions/*/installation/bin; do
    [ -x "$_litter_node_bin/node" ] && _litter_path_prepend "$_litter_node_bin"
  done
fi
_litter_path_prepend "$HOME/.asdf/shims"
_litter_path_prepend "$HOME/.local/share/mise/shims"
export PATH
