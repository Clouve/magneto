# shellcheck shell=bash
# ============================================================================
# Root's reads and writes on the app user's volume (the entrypoint sources it)
# ============================================================================
# The entrypoint runs as root, and the volume it reads and writes belongs to
# the app's user (www-data). Code that runs as www-data can put a link, a pipe
# or a folder at any name there, or swap a folder for a link while the
# entrypoint works. cat, touch and echo > follow such a link: root would read a
# file from outside the volume into the log, or write wherever the link
# points. So:
#   - in_folder runs a command inside the folder it concerns, once the kernel
#     (getcwd, through /bin/pwd -P) has shown that folder to be the one named,
#     with no link on the way. The command names the file by its plain name,
#     so a folder swapped for a link afterwards moves the folder, not the work.
#   - plain_file and safe_read take a file only when it is a regular file and
#     not a link. safe_read opens it with O_NOFOLLOW and O_NONBLOCK, so a link
#     or a pipe put there after the check is neither followed nor waited on,
#     and reads at most the bytes asked for.
#   - safe_write and safe_put put the text into a new file that they create
#     themselves (dd conv=excl, O_CREAT|O_EXCL), with its mode from the umask,
#     then rename that file over the name (mv -fT). A link there is replaced,
#     never written through, and nothing is opened or changed by name after the
#     file is made. clear_temp_files removes what a start cut off between the
#     two left.
#   - remove_entry and make_folder remove or make one entry, from inside the
#     folder above it.
#   - copy_tree copies a tree of the image's over a folder on the volume, one
#     folder at a time from inside it, replacing a link where the tree has a
#     file or a folder instead of writing through it.
# None of them prints what was in a file. The Gibbon and ownCloud images carry
# the same copy of this file (tests/gibbon-root-paths.test.sh).
# ============================================================================

# in_folder DIR COMMAND...: runs COMMAND in a subshell whose working folder is DIR, once cd -P has moved there and
# /bin/pwd -P has shown that the folder the subshell is in has DIR's own path: a folder, with no link on the way.
# /bin/pwd asks the kernel (getcwd). Bash's builtin pwd -P doesn't: it resolves the path that cd stored once more, so a
# name swapped to a link for cd's chdir and back again before the check would pass it while the subshell sits in the
# link's target. Status 125 when DIR fails the check, COMMAND's status otherwise.
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

# plain_file FILE: status 0 when FILE is a regular file and not a link, in a folder with no link on the way.
plain_file() {
  in_folder "$(dirname -- "$1")" _plain_here "${1##*/}"
}
_plain_here() { [[ -f "$1" && ! -L "$1" ]]; }

# safe_read FILE MAX: prints what FILE holds, at most MAX bytes, when FILE is a regular file and not a link, in a
# folder with no link on the way. A NUL byte comes out as ?, so a caller's check of the text sees it. Status 0 when it
# read the file (an empty one too), 1 otherwise, and then it prints nothing.
safe_read() {
  in_folder "$(dirname -- "$1")" _safe_read_here "${1##*/}" "$2"
}
_safe_read_here() {
  [[ -f "$1" && ! -L "$1" && "$2" =~ ^[1-9][0-9]{0,6}$ ]] || return 1
  # dd doesn't follow a link (nofollow) or wait on a pipe (nonblock) put there after the test above.
  set -o pipefail
  dd if="$1" iflag=nofollow,nonblock bs="$2" count=1 status=none 2>/dev/null | tr '\0' '?'
}

# safe_write FILE TEXT: writes TEXT and a newline (as echo did) to a new file in FILE's folder, root's with mode 644,
# then renames it over FILE with mv -fT, all inside that folder (in_folder). The new file has a name with 64 random bits,
# and dd creates it only if nothing is at that name (conv=excl, O_CREAT|O_EXCL, which a link of any kind makes fail),
# so the text goes only into a file this call made. The rename (rename(2)) replaces whatever is at FILE, a link
# included, without following it; a folder or anything else that isn't a regular file is removed first. Status 1, with
# a message, when it can't: the folder is missing or has a link on the way to it, the new file can't be made, or FILE
# isn't a regular file after the rename (something swapped the new file for a link or a folder).
safe_write() {
  printf '%s\n' "$2" | _put "$1" new
}

# safe_put FILE: as safe_write, with what comes on stdin, byte for byte, as the text. When a regular file (not a link)
# is at FILE, the new file keeps its owner, group and read and write bits, as a write in place did (chown -h, which
# never follows a link, on the new file by its plain name; the bits from the umask); otherwise it is root's, mode 644.
safe_put() {
  _put "$1" keep
}

# _put FILE new|keep: safe_write's and safe_put's work (stdin is the text), and their messages.
_put() {
  local file="$1" rc=0 why=""
  in_folder "$(dirname -- "$file")" _put_here "${file##*/}" "$2" || rc=$?
  case $rc in
    0) return 0 ;;
    125) why=": its folder is missing or there is a link on the way to it" ;;
    3) why=": what is there can't be removed" ;;
    4) why=": something replaced the new file before it was renamed" ;;
  esac
  echo "✗ Error: can't write $file$why" >&2
  return 1
}
_put_here() {
  local name="$1" uid=0 gid=0 mode=644 st rand tmp
  if [[ -f "$name" && ! -L "$name" ]]; then
    if [[ "$2" == keep ]] && st="$(stat -c '%u %g %a' -- "$name" 2>/dev/null)"; then
      read -r uid gid mode <<< "$st"
      [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{1,4}$ ]] || { uid=0 gid=0 mode=644; }
    fi
  elif [[ -e "$name" && ! -L "$name" ]]; then
    rm -rf -- "$name" 2>/dev/null || return 3
  fi
  rand="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$rand" =~ ^[0-9a-f]{16}$ ]] || return 1
  tmp=".$name.$rand"
  # The umask gives the new file the read and write bits of MODE (and no execute bits).
  if ! (umask "$(printf '%03o' $(( (~8#$mode & 8#666) | 8#111 )))" &&
          dd of="$tmp" conv=excl oflag=nofollow status=none 2>/dev/null) ||
      { [[ "$uid:$gid" != 0:0 ]] && ! chown -h -- "$uid:$gid" "$tmp" 2>/dev/null; } ||
      ! mv -fT -- "$tmp" "$name" 2>/dev/null; then
    rm -rf -- "$tmp" 2>/dev/null || :   # whatever is at that name in this folder; a link goes as a link
    return 1
  fi
  [[ -f "$name" && ! -L "$name" ]] || return 4
}

# clear_temp_files DIR NAME...: removes, from inside DIR (in_folder), the regular files named .NAME.<16 hex digits>,
# which safe_write, safe_put and update-config.sh leave when a start is cut off between making the new file and
# renaming it. Plain names only; a link, a folder or anything else at such a name is left. Nothing happens when DIR
# is missing or has a link on the way. Status 0.
clear_temp_files() {
  local dir="$1"
  shift
  in_folder "$dir" _clear_temp_files_here "$@" 2>/dev/null || :
  return 0
}
_clear_temp_files_here() {
  local name f
  for name in "$@"; do
    for f in ".$name".????????????????; do
      [[ "${f#".$name".}" =~ ^[0-9a-f]{16}$ && -f "$f" && ! -L "$f" ]] || continue
      rm -f -- "$f" 2>/dev/null
    done
  done
}

# remove_entry PATH: removes what is at PATH, from inside the folder above it, without following a link (rm -rf on a
# link removes the link). Status 0 when nothing is left there.
remove_entry() {
  in_folder "$(dirname -- "$1")" rm -rf -- "${1##*/}" 2>/dev/null
}

# make_folder PATH: makes the folder PATH, from inside the folder above it (mkdir -p: nothing happens when it is
# there). Status 0 when it is there.
make_folder() {
  in_folder "$(dirname -- "$1")" mkdir -p -- "${1##*/}" 2>/dev/null
}

# copy_tree SRC DEST: copies the tree SRC (the image's) over the folder DEST as cp -prf SRC/. DEST/ did: files are
# replaced, folders merged, and what DEST holds that SRC doesn't is kept. Each folder of DEST is worked on from inside
# (in_folder), by plain names, parents first. Where SRC has a folder, a link in DEST is removed (never followed) and a
# real folder made; files are copied with cp --remove-destination, which removes what is at the name (a link as a
# link) and makes the file anew with O_EXCL, so nothing is written through a link. Mode, owner and times come from SRC
# (cp -p). Status 1 when a folder of DEST fails the check (a link swapped in meanwhile) or cp fails, for example on a
# folder where SRC has a file, or a file where SRC has a folder, as cp -r failed there.
copy_tree() {
  local src="$1" dest="$2" dir
  while IFS= read -r -d '' dir; do
    in_folder "$dest/$dir" _copy_tree_here "$src/$dir" || return 1
  done < <(cd -- "$src" && find . -type d -print0)
}
_copy_tree_here() {
  local e name files=()
  for e in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [[ -e "$e" || -L "$e" ]] || continue
    name="${e##*/}"
    if [[ -d "$e" && ! -L "$e" ]]; then
      if [[ -L "$name" ]]; then
        rm -f -- "./$name" || return 1
      fi
      [[ -d "$name" && ! -L "$name" ]] || mkdir -- "./$name" || return 1
    else
      files+=("$e")
    fi
  done
  [[ ${#files[@]} -eq 0 ]] || cp -pP --remove-destination -t . -- "${files[@]}"
}
