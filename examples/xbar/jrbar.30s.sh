#!/bin/bash
# <xbar.title>JR-Bar</xbar.title>
# <xbar.desc>Your coding agents and their quota, from JR-Bar's local status endpoint.</xbar.desc>
# <xbar.author>JR-Bar</xbar.author>
# <xbar.dependencies>JR-Bar with Settings › Remote › Serve status on</xbar.dependencies>
#
# An xbar (and SwiftBar) plugin that reads `jrbar serve`'s loopback
# /status.json every 30 seconds. Turn on Serve status in JR-Bar's Settings,
# then drop this file into your xbar or SwiftBar plugins folder. The bearer
# token comes from JRBAR_SERVE_TOKEN, else ~/.local/state/jrbar/serve-token.
# Loopback only and read only; it shows numbers and words, no meters.
URL="${JRBAR_SERVE_URL:-http://127.0.0.1:8737/status.json}"
TOKEN="${JRBAR_SERVE_TOKEN:-$(cat "$HOME/.local/state/jrbar/serve-token" 2>/dev/null)}"

body="$(curl -fsS --max-time 3 -H "Authorization: Bearer $TOKEN" "$URL" 2>/dev/null)"
if [ -z "$body" ]; then
    echo "JR ·"
    echo "---"
    echo "JR-Bar's status endpoint is not answering | color=gray"
    echo "Turn on Settings › Remote › Serve status | color=gray"
    exit 0
fi

field() { printf '%s' "$body" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null; }

active="$(field agents.lifecycle_counts.active)"
waiting="$(field agents.lifecycle_counts.waiting)"
failed="$(field agents.lifecycle_counts.failed)"
title="JR"
[ "${waiting:-0}" -gt 0 ] 2>/dev/null && title="$title ${waiting} waiting"
[ "${active:-0}" -gt 0 ] 2>/dev/null && title="$title ${active} working"
[ "${failed:-0}" -gt 0 ] 2>/dev/null && title="$title ${failed} failed"
[ "$title" = "JR" ] && title="JR idle"
echo "$title"
echo "---"

now="$(date +%s)"
index=0
while provider="$(field "usage.providers.$index.provider_id")" && [ -n "$provider" ]; do
    left="$(field "usage.providers.$index.quota.remaining_percent")"
    reset="$(field "usage.providers.$index.quota.next_reset_at")"
    line="$provider"
    if [ -n "$left" ]; then
        line="$line $(printf '%.0f' "$left")% left"
    else
        line="$line $(field "usage.providers.$index.state" | tr '_' ' ')"
    fi
    if [ -n "$reset" ]; then
        minutes=$(( ( ${reset%.*} - now ) / 60 ))
        if [ "$minutes" -ge 1440 ]; then line="$line · resets in $(( minutes / 1440 ))d"
        elif [ "$minutes" -ge 60 ]; then line="$line · resets in $(( minutes / 60 ))h $(( minutes % 60 ))m"
        elif [ "$minutes" -ge 0 ]; then line="$line · resets in ${minutes}m"
        fi
    fi
    echo "$line"
    index=$(( index + 1 ))
done
echo "---"
echo "Open JR-Bar's Usage Center | href=jrbar://usage"
