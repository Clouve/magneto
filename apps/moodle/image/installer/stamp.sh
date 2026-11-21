# shellcheck shell=bash
# ============================================================================
# The version stamp, read and written safely (entrypoint.sh sources this file)
# ============================================================================
# The entrypoint runs as root and keeps its records in clouve/installed/ on the
# site's volume: the version stamp (the Moodle $version the site runs), a
# timestamp for each release, and the install markers. www-data can change
# anything there, because the entrypoint gives /var/www/html to www-data at
# every start, and a process of www-data's can still be running while the
# entrypoint works (one that a plugin's upgrade code left behind). So:
#   - Every read, write and removal here happens inside the folder it concerns
#     (in_folder): a subshell moves into the folder and checks its real path
#     first, then names the file by its relative name. A folder on the way
#     that is swapped for a link after that moves the folder, not the work.
#   - stamp_read takes the stamp only from a regular file that holds nothing
#     but digits. The entrypoint compares the stamp with [[ -gt ]], which bash
#     evaluates as arithmetic: a value such as a[$(cmd)] would run cmd as
#     root, and other text (a password, through a link) would be printed in
#     the error.
#   - safe_write writes the text only into a new file it creates itself, and
#     renames that over the old name, so a link there is replaced, never
#     written through, and nothing is changed by name after the file is made.
#   - stamp_folders removes a link at clouve/ or clouve/installed/ before
#     anything reads or writes there.
# None of them prints anything that was in a file.
# ============================================================================

# in_folder DIR COMMAND...: runs COMMAND in a subshell whose working folder is DIR, once cd -P has moved there and
# /bin/pwd -P has shown that the folder the subshell is in has DIR's own path: a folder, with no link on the way.
# /bin/pwd asks the kernel (getcwd). Bash's builtin pwd -P doesn't: it resolves the path that cd stored once more, so a
# name swapped to a link for cd's chdir and back again before the check would pass it while the subshell sits in the
# link's target. COMMAND names things in DIR by relative names, so swapping DIR or a folder above it for a link after
# the check can't send it anywhere else: the working folder stays the one that was checked, wherever it is moved.
# Status 125 when DIR fails the check, COMMAND's status otherwise.
in_folder() {
  local dir="$1" want
  shift
  want="$(realpath -sm -- "$dir" 2>/dev/null)" || return 125
  (
    if ! cd -P -- "$dir" 2>/dev/null || [[ "$(/bin/pwd -P 2>/dev/null)" != "$want" ]]; then
      exit 125
    fi
    "$@"
  )
}

# stamp_read FILE: prints FILE's value when FILE is a regular file, not a link, in a folder with no link on the way,
# whose whole content is digits (at most 18, so that bash's 64-bit -gt compares it as it is, and one newline at the end
# allowed). Prints nothing otherwise, and never anything else from the file. Its status is always 0.
stamp_read() {
  in_folder "$(dirname -- "$1")" _stamp_read_here "${1##*/}" || :
  return 0
}

# _stamp_read_here NAME: stamp_read's work, inside the folder (in_folder).
_stamp_read_here() {
  local value
  [[ -f "$1" && ! -L "$1" ]] || return 0
  # dd reads at most 20 bytes, and doesn't follow a link (nofollow) or wait on a pipe (nonblock) put there after the
  # test above. tr turns a NUL byte, which bash would drop, into a character the check refuses, and the x keeps the
  # newlines at the end, which $( ) would drop.
  value="$(dd if="$1" iflag=nofollow,nonblock bs=20 count=1 status=none 2>/dev/null | tr '\0' '?'; echo x)"
  value="${value%x}"
  value="${value%$'\n'}"
  if [[ "$value" =~ ^[0-9]{1,18}$ ]]; then
    printf '%s\n' "$value"
  fi
  return 0
}

# safe_write FILE TEXT: writes TEXT and a newline (as echo did) to a new file in FILE's folder, then renames it over
# FILE with mv -fT, all inside that folder (in_folder). The new file has a name with 64 random bits, and dd creates it
# only if nothing is at that name (conv=excl, O_CREAT|O_EXCL, which a link of any kind makes fail), with mode 644 from
# the umask, so the text goes only into a file this call made and nothing is opened or changed by name afterwards. The
# rename (rename(2)) replaces whatever is at FILE, a link included, without following it; a folder or anything else
# that isn't a regular file is removed first. Status 1, with a message, when it can't: the folder is missing or has a
# link on the way to it, the new file can't be made, or FILE isn't a regular file after the rename (something swapped
# the new file for a link or a folder). When something swaps it for a regular file of its own, that file is what FILE
# holds.
safe_write() {
  local file="$1" rc=0 why=""
  in_folder "$(dirname -- "$file")" _safe_write_here "${file##*/}" "$2" || rc=$?
  case $rc in
    0) return 0 ;;
    125) why=": its folder is missing or there is a link on the way to it" ;;
    3) why=": what is there can't be removed" ;;
    4) why=": something replaced the new file before it was renamed" ;;
  esac
  echo "✗ Error: can't write $file$why" >&2
  return 1
}

# _safe_write_here NAME TEXT: safe_write's work, inside the folder (in_folder), by relative names.
_safe_write_here() {
  local name="$1" rand tmp
  if [[ -e "$name" && ! -L "$name" && ! -f "$name" ]]; then
    rm -rf -- "$name" 2>/dev/null || return 3
  fi
  rand="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$rand" =~ ^[0-9a-f]{16}$ ]] || return 1
  tmp=".$name.$rand"
  if ! printf '%s\n' "$2" | (umask 022 && dd of="$tmp" conv=excl oflag=nofollow status=none 2>/dev/null) ||
      ! mv -fT -- "$tmp" "$name" 2>/dev/null; then
    rm -rf -- "$tmp" 2>/dev/null || :   # whatever is at that name in this folder; a link goes as a link
    return 1
  fi
  [[ -f "$name" && ! -L "$name" ]] || return 4
}

# stamp_folders SITE: SITE/clouve and SITE/clouve/installed hold the stamp and the markers, so they must be real
# folders, or root's reads and writes there would go wherever a link points. A link at either, or anything else that
# isn't a folder, is removed without being followed, with a warning that names it. The removal runs in the folder
# above it (in_folder). For an installed site (one with SITE/config.php) both folders are then made again, empty, one
# level at a time, so the site isn't taken for a new one, and the entrypoint records the stamp from the site's code. A
# site without config.php installs as a new site, as it would with no clouve/installed/. Status 1, with a message, when
# it can't.
stamp_folders() {
  local site="$1" dir
  for dir in "$site/clouve" "$site/clouve/installed"; do
    if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) ]]; then
      echo "⚠ Warning: $dir is a link or not a folder, so it is removed without being followed"
      if ! in_folder "$(dirname -- "$dir")" rm -rf -- "${dir##*/}" 2>/dev/null; then
        echo "✗ Error: can't remove $dir" >&2
        return 1
      fi
      if [[ -f "$site/config.php" ]] && ! { in_folder "$site" mkdir -p -- clouve &&
          in_folder "$site/clouve" mkdir -p -- installed; } 2>/dev/null; then
        echo "✗ Error: can't make $site/clouve/installed" >&2
        return 1
      fi
    fi
  done
}
