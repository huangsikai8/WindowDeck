#!/bin/zsh
#
# Records where macOS's web-thumbnail helpers come from, and what they cost.
#
# `WebThumbnailExtension` and its `WebContent.EnhancedSecurity` children are the
# QuickLook thumbnail path for web content. They are launched by
# `com.apple.quicklook.ThumbnailsAgent` on behalf of whichever process asked for
# a thumbnail — a Finder window, Spotlight, or any application showing an
# open/save panel, since the file browser in one previews what it lists.
#
# They matter because a single one can reach a gigabyte of memory and stay
# there: WebKit's table layout has a pathological case, and a helper that hits
# it renders until it is suspended rather than exiting. Several at once is
# enough to push a 16 GB machine into swap, at which point *every* application
# stutters — including whichever one happens to be in front, which is how the
# cause gets misattributed.
#
# This script exists because the problem is intermittent, so the question
# "which process asked for that thumbnail" can only be answered while it is
# happening. Leave it running; it costs one `ps` every five seconds.
#
#   ./Tools/watch-webthumbnails.sh [logfile]
#
# Default log: ~/Library/Logs/webthumbnail-watch.log

LOG=${1:-$HOME/Library/Logs/webthumbnail-watch.log}
PATTERN="WebThumbnailExtension|WebContent.EnhancedSecurity"
# A helper doing ordinary work never gets near this. One stuck in layout passes
# it within a minute or two.
RUNAWAY_MB=300

mkdir -p "${LOG:h}"
print "=== watch started $(date '+%Y-%m-%d %H:%M:%S'), threshold ${RUNAWAY_MB} MB ===" >> "$LOG"

typeset -A seen
typeset -A flagged

note() { print "$(date '+%H:%M:%S') $*" >> "$LOG" }

# Who asked for it. RunningBoard names the responsible application when it
# resolves an extension or an open-panel service, which is the only place the
# chain is written down.
blame() {
  local since=$1
  /usr/bin/log show --start "$since" --info --debug \
      --predicate 'eventMessage CONTAINS "Resolved pid" AND (eventMessage CONTAINS "openAndSavePanelService" OR eventMessage CONTAINS "QuickLookUIService")' \
      --style compact 2>/dev/null \
    | grep -o 'app<application\.[^(]*' | sed 's/app<application\.//' | sort -u | paste -sd, -
}

while true; do
  now=$(ps -Ao pid=,rss=,comm= | grep -E "$PATTERN")

  while read -r pid rss comm; do
    [[ -z $pid ]] && continue
    mb=$(( rss / 1024 ))

    if [[ -z ${seen[$pid]} ]]; then
      seen[$pid]=1
      wd=$(pgrep -x WindowDeck >/dev/null && print yes || print no)
      note "SPAWN pid=$pid  WindowDeck running: $wd  ${comm:t}"
      # Look back far enough to cover the request that preceded the launch.
      who=$(blame "$(date -v-2M '+%Y-%m-%d %H:%M:%S')")
      note "      requested by: ${who:-(no open-panel or Quick Look client in the last 2 minutes)}"
    fi

    if (( mb > RUNAWAY_MB )) && [[ -z ${flagged[$pid]} ]]; then
      flagged[$pid]=1
      wd=$(pgrep -x WindowDeck >/dev/null && print yes || print no)
      note "RUNAWAY pid=$pid at ${mb} MB  WindowDeck running: $wd"
      # The stack is what identifies the pathology; without it a runaway is
      # just a big number.
      /usr/bin/sample "$pid" 2 -f /tmp/webthumb-$pid.sample >/dev/null 2>&1 \
        && note "      stack saved to /tmp/webthumb-$pid.sample" \
        && grep -m1 -E "RenderTable|RenderBlock|WebCore::" /tmp/webthumb-$pid.sample \
             | sed 's/^/      /' >> "$LOG"
    fi
  done <<< "$now"

  sleep 5
done
