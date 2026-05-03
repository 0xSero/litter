# Scan ~/.pi/agent/sessions for thread/session metadata and emit one
# tab-separated record per session:
#   P\t<jsonl_path>\t<session_id>\t<cwd>\t<parent_path>\t<created_rfc3339>\t<modified_ms>\t<message_count>\t<name>\t<first_user_text>
clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}
mtime_ms() {
  if seconds=$(stat -c %Y "$1" 2>/dev/null); then
    :
  elif seconds=$(stat -f %m "$1" 2>/dev/null); then
    :
  else
    seconds=0
  fi
  case "$seconds" in
    ''|*[!0-9]*) seconds=0 ;;
  esac
  printf '%s000' "$seconds"
}
list_paths() {
  if stat -c '%Y	%n' "$root" >/dev/null 2>&1; then
    find "$root" -type f -name '*.jsonl' -exec stat -c '%Y	%n' {} \; 2>/dev/null
  else
    find "$root" -type f -name '*.jsonl' -exec stat -f '%m	%N' {} \; 2>/dev/null
  fi | sort -rn | cut -f2-
}
agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
case "$agent_dir" in "~") agent_dir="$HOME" ;; "~/"*) agent_dir="$HOME/${agent_dir#~/}" ;; esac
root="$agent_dir/sessions"
[ -d "$root" ] || exit 0
list_paths | while IFS= read -r path; do
  [ -f "$path" ] || continue
  modified_ms=$(mtime_ms "$path")
  meta=$(
    awk '
      function clean(s) {
        gsub(/\\n/, " ", s)
        gsub(/\\r/, " ", s)
        gsub(/\\t/, " ", s)
        gsub(/\t/, " ", s)
        gsub(/\r/, " ", s)
        gsub(/\n/, " ", s)
        gsub(/\\"/, "\"", s)
        return s
      }
      function field(line, key, pat, rest) {
        pat = "\"" key "\"[[:space:]]*:[[:space:]]*\""
        if (!match(line, pat)) return ""
        rest = substr(line, RSTART + RLENGTH)
        if (match(rest, /([^"\\]|\\.)*/)) return clean(substr(rest, RSTART, RLENGTH))
        return ""
      }
      {
        if (id == "" && $0 ~ /"type"[[:space:]]*:[[:space:]]*"session"/) {
          id = field($0, "id")
          cwd = field($0, "cwd")
          parent = field($0, "parentSession")
          created = field($0, "timestamp")
        }
        if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"session_info"/) {
          name = field($0, "name")
        }
        if ($0 ~ /"type"[[:space:]]*:[[:space:]]*"message"/) {
          count += 1
          if (first == "" && $0 ~ /"role"[[:space:]]*:[[:space:]]*"user"/) {
            text = field($0, "text")
            if (text == "") text = field($0, "content")
            if (text != "") first = text
          }
        }
      }
      END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s", id, cwd, parent, created, name, count + 0, first }
    ' "$path" 2>/dev/null
  ) || meta="$(printf '\t\t\t\t\t0\t')"
  id=${meta%%	*}
  rest=${meta#*	}
  cwd=${rest%%	*}
  rest=${rest#*	}
  parent=${rest%%	*}
  rest=${rest#*	}
  created=${rest%%	*}
  rest=${rest#*	}
  name=${rest%%	*}
  rest=${rest#*	}
  message_count=${rest%%	*}
  first=${rest#*	}
  [ -n "$id" ] || continue
  printf 'P\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(clean_field "$path")" \
    "$(clean_field "$id")" \
    "$(clean_field "$cwd")" \
    "$(clean_field "$parent")" \
    "$(clean_field "$created")" \
    "$modified_ms" \
    "$message_count" \
    "$(clean_field "$name")" \
    "$(clean_field "$first")"
done
