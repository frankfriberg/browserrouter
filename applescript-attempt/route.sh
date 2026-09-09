#!/bin/sh
# Which Dia profile a url belongs in. Prints one of: work | personal | native
#
#   route.sh <url>              the verdict alone, which is what DiaRouter reads
#   route.sh --explain <url>    the verdict, a tab, and the rule that produced it
#
# **`native` means hand the url to Dia untouched**, so it opens exactly where it would
# have without a router in the way. Only the hosts that serve both identities are worth
# steering — github.com and linear.app each answer to both accounts, and the
# discriminator is the path, which is why no browser's own domain setting can express it.
#
# The rules are data in rules.tsv, not regexes here, so the editor in DiaRouter.app can
# add and remove them without anyone hand-writing a pattern.
RULES="$(dirname "$0")/rules.tsv"
TAB=$(printf '\t')

explain=no
if [ "$1" = "--explain" ]; then explain=yes; shift; fi
u=$1

# Escape every regex metacharacter, because a pattern in rules.tsv is a literal. Without
# this a `host` rule for `allgravy.com` also matches `allgravyXcom`.
esc() { printf '%s' "$1" | sed 's/[][\.*^$(){}?+|/]/\\&/g'; }

decide() {
  [ -n "$u" ] || return 0
  [ -r "$RULES" ] || return 0

  # **Sorted by specificity, never by line order** — regex, then prefix, then pathhas,
  # then host, and the longer pattern first within a kind. `999-length` is what puts the
  # longer one first once the whole key sorts ascending. So a rule for
  # github.com/buttersolutions beats one for github.com and no one has to remember to
  # keep it above.
  awk -F"$TAB" '
    /^[[:space:]]*(#|$)/ { next }
    NF >= 3 {
      rank = ($2=="regex")?0:($2=="prefix")?1:($2=="pathhas")?2:($2=="host")?3:9
      if (rank == 9) next
      printf "%d\t%03d\t%s\t%s\t%s\n", rank, 999-length($3), $1, $2, $3
    }' "$RULES" | sort | while IFS="$TAB" read -r _rank _len profile kind pat; do
      case "$kind" in
        host)
          re="^https?://([a-z0-9_-]+\.)*$(esc "$pat")([/?#:]|\$)"
          ;;
        prefix)
          re="^https?://(www\.)?$(esc "$pat")([/?#]|\$)"
          ;;
        pathhas)
          h=${pat%%:*}
          n=${pat#*:}
          re="^https?://(www\.)?$(esc "$h")/[^?#]*$(esc "$n")"
          ;;
        regex)
          re=$pat
          ;;
        *)
          continue
          ;;
      esac
      if printf '%s' "$u" | grep -qiE "$re"; then
        printf '%s%s%s %s' "$profile" "$TAB" "$kind" "$pat"
        break
      fi
    done
}

# **The loop's output is captured rather than printed from inside it.** It runs in a
# subshell at the end of a pipe, so an `exit` there ends only the subshell — a script
# that printed the verdict in the loop printed `native` after it as well.
verdict=$(decide)
[ -n "$verdict" ] || verdict="native${TAB}no rule matched"

if [ "$explain" = yes ]; then
  printf '%s\n' "$verdict"
else
  printf '%s\n' "${verdict%%"$TAB"*}"
fi
