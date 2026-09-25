#!/bin/sh
# A JR-Bar usage hook that shows a macOS notification.
#
#   jrbar usage-hooks add --event quota_low "$PWD/examples/usage-hooks/notify.sh"
#   jrbar usage-hooks enable
#
# The hook runs without a shell of its own and with a small environment; the
# event's facts arrive as JRBAR_* variables (and as JSON on stdin, which this
# one ignores). Nothing leaves the Mac.
provider="${JRBAR_PROVIDER:-a provider}"
case "${JRBAR_EVENT:-}" in
    quota_low) text="$provider is down to ${JRBAR_REMAINING_PERCENT%%.*}% left" ;;
    quota_reached) text="$provider has run out for this window" ;;
    quota_reset) text="$provider's window reset" ;;
    provider_unavailable) text="$provider stopped answering (${JRBAR_STATE:-unknown})" ;;
    provider_recovered) text="$provider is answering again" ;;
    *) text="$provider: ${JRBAR_EVENT:-usage event}" ;;
esac
/usr/bin/osascript -e "display notification \"$text\" with title \"JR-Bar\"" >/dev/null 2>&1
exit 0
