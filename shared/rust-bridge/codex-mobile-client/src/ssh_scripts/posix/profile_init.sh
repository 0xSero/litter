# Resolve background SSH tools without executing user startup files. Sourcing
# shell profiles (even in a subshell) can open desktop terminals and repeat
# expensive interactive initialization for every RPC. Preserve the inherited
# PATH and add known installation directories; generated commands run under sh.
_litter_path_prepend() {
  [ -n "$1" ] || return 0
  case ":${PATH:-}:" in
    *":$1:"*) ;;
    *) [ -d "$1" ] && PATH="$1${PATH:+:$PATH}" ;;
  esac
}

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
