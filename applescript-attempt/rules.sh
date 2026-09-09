#!/bin/sh
# Read and edit rules.tsv. The editor in DiaRouter.app is a thin caller of this, so the
# rules can be changed and checked from a shell without clicking through dialogs.
#
#   rules.sh list                          line<TAB>profile<TAB>kind<TAB>pattern
#   rules.sh add <profile> <kind> <pattern>
#   rules.sh delete <line>
#
# **Rules are addressed by their line number in the file**, which `list` hands out. The
# alternative is matching on content, and two identical rules would then delete each
# other's line.
RULES="$(dirname "$0")/rules.tsv"
TAB=$(printf '\t')

die() { printf '%s\n' "$1" >&2; exit 1; }

case $1 in
  list)
    [ -r "$RULES" ] || exit 0
    grep -nvE '^[[:space:]]*(#|$)' "$RULES" | sed "s/:/$TAB/"
    ;;

  add)
    profile=$2; kind=$3; pattern=$4
    case $profile in work|personal) ;; *) die "profile must be work or personal" ;; esac
    case $kind in host|prefix|pathhas|regex) ;; *) die "kind must be host, prefix, pathhas or regex" ;; esac
    [ -n "$pattern" ] || die "a rule needs a pattern"
    case $pattern in *"$TAB"*) die "a pattern cannot contain a tab" ;; esac
    # **A pathhas pattern is two things joined by a colon**, and half of one silently
    # never matches, so it is refused here rather than at routing time.
    if [ "$kind" = pathhas ]; then
      case $pattern in
        *:*) [ -n "${pattern%%:*}" ] && [ -n "${pattern#*:}" ] || die "pathhas wants host:word" ;;
        *) die "pathhas wants host:word, as in linear.app:all-gravy" ;;
      esac
    fi
    if [ "$kind" = regex ]; then
      printf '' | grep -qE "$pattern" 2>/dev/null || printf '%s' x | grep -qE "$pattern" 2>/dev/null || \
        grep -qE "$pattern" /dev/null 2>/dev/null || die "that is not a valid extended regex"
    fi
    if "$(dirname "$0")/rules.sh" list | cut -f2- | grep -qxF "$profile$TAB$kind$TAB$pattern"; then
      die "that rule is already there"
    fi
    printf '%s%s%s%s%s\n' "$profile" "$TAB" "$kind" "$TAB" "$pattern" >> "$RULES"
    printf 'added %s %s -> %s\n' "$kind" "$pattern" "$profile"
    ;;

  delete)
    n=$2
    case $n in ''|*[!0-9]*) die "delete wants a line number from list" ;; esac
    line=$(sed -n "${n}p" "$RULES")
    [ -n "$line" ] || die "no line $n"
    case $line in '#'*|'') die "line $n is a comment, not a rule" ;; esac
    tmp=$(mktemp) || die "no temp file"
    awk -v n="$n" 'NR != n' "$RULES" > "$tmp" && mv "$tmp" "$RULES"
    printf 'deleted %s\n' "$(printf '%s' "$line" | tr '\t' ' ')"
    ;;

  *)
    die "usage: rules.sh list | add <profile> <kind> <pattern> | delete <line>"
    ;;
esac
