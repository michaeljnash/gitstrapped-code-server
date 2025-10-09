#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <target-file> <faux-diff-file>" >&2
  exit 2
fi

TARGET="$1"
DIFF="$2"

[ -f "$TARGET" ] || { echo "target not found: $TARGET" >&2; exit 2; }
[ -f "$DIFF" ]   || { echo "diff not found:   $DIFF"   >&2; exit 2; }

ts="$(date +%Y%m%d-%H%M%S)"
BACKUP="${TARGET}.bak.${ts}"
cp -f -- "$TARGET" "$BACKUP"
echo "Backup: $BACKUP"

# Build ops: REPLACE, DELETE, ADD
# Pair a -line followed immediately by a +line => REPLACE
# Lone -line => DELETE
# Lone +line => ADD (append later if not already present)
awk -v tgt="$TARGET" -v bak="$BACKUP" '
  BEGIN {
    FS = "\n"; ORS = "\n"
  }

  function flush_del() {
    if (pending_del != "") {
      ops_len++
      ops_type[ops_len] = "DELETE"
      ops_old[ops_len]  = pending_del
      ops_new[ops_len]  = ""
      pending_del = ""
    }
  }

  # parse the faux diff into ops_*
  FNR==NR {
    if ($0 ~ /^[ \t]*@@/) next
    if ($0 ~ /^[ \t]*$/)   next

    if (substr($0,1,1) == "-") {
      flush_del()
      pending_del = substr($0,2)
      next
    }

    if (substr($0,1,1) == "+") {
      line = substr($0,2)
      if (pending_del != "") {
        ops_len++
        ops_type[ops_len] = "REPLACE"
        ops_old[ops_len]  = pending_del
        ops_new[ops_len]  = line
        pending_del = ""
      } else {
        ops_len++
        ops_type[ops_len] = "ADD"
        ops_old[ops_len]  = ""
        ops_new[ops_len]  = line
      }
      next
    }
    next
  }

  # apply ops to target
  FNR!=NR {
    # no-op: we only read DIFF in the first pass
  }

  END {
    flush_del()

    # load file
    while ((getline l < tgt) > 0) {
      file_n++
      file_lines[file_n] = l
      present[l] = 1
    }
    close(tgt)

    # build quick lookup tables for literal match
    for (i=1; i<=ops_len; i++) {
      if (ops_type[i] == "REPLACE") repl_old[ ops_old[i] ] = ops_new[i]
      else if (ops_type[i] == "DELETE") del_set[ ops_old[i] ] = 1
      else if (ops_type[i] == "ADD") { add_list_len++; add_list[add_list_len] = ops_new[i] }
    }

    # write new file
    out = tgt ".tmp." strftime("%Y%m%d%H%M%S")
    for (i=1; i<=file_n; i++) {
      l = file_lines[i]
      if (l in del_set) {
        # skip (deleted)
        continue
      }
      if (l in repl_old) {
        nl = repl_old[l]
        print nl > out
        new_present[nl] = 1
      } else {
        print l > out
        new_present[l] = 1
      }
    }

    # append ADDs if not already present
    for (j=1; j<=add_list_len; j++) {
      a = add_list[j]
      if (!(a in new_present)) {
        print a > out
        new_present[a] = 1
        printf("add    : [%s]\n", a) > "/dev/stderr"
      } else {
        printf("add    : skipped (already present) [%s]\n", a) > "/dev/stderr"
      }
    }
    close(out)

    # replace original
    if (system("mv -- " out " " tgt) != 0) {
      print "error: failed to move new file into place" > "/dev/stderr"
      exit 1
    }

    # log operations
    for (k=1; k<=ops_len; k++) {
      if (ops_type[k] == "REPLACE") printf("replace: [%s] -> [%s]\n", ops_old[k], ops_new[k]) > "/dev/stderr"
      else if (ops_type[k] == "DELETE") printf("delete : [%s]\n", ops_old[k]) > "/dev/stderr"
    }

    print "Done. Review with: git -c color.ui=always diff -- " tgt > "/dev/stderr"
  }
' "$DIFF" /dev/null
