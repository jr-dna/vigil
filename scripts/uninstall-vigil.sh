#!/bin/bash
#
# Removes Vigil and everything it wrote.
#
# The in-app "Uninstall Vigil…" item in the gear menu does the same thing and
# is easier. This exists for the case where the app is already gone from
# /Applications and its preferences are still sitting around.

set -uo pipefail

BUNDLE_ID="music.jordanalegant.vigil"

echo "Removing Vigil..."

if pgrep -x Vigil >/dev/null 2>&1; then
    echo "  quitting the running copy"
    pkill -x Vigil 2>/dev/null || true
    sleep 1
fi

for app in /Applications/Vigil.app "$HOME/Applications/Vigil.app"; do
    if [ -d "$app" ]; then
        echo "  $app"
        rm -rf "$app"
    fi
done

# Preferences. `defaults delete` also clears cfprefsd's in-memory copy, which
# a bare rm of the plist does not — without it the settings can reappear.
if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "  preferences"
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
fi

rm -f  "$HOME/Library/Preferences/$BUNDLE_ID.plist"
rm -rf "$HOME/Library/Caches/$BUNDLE_ID"
rm -rf "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"

echo
echo "Done. Vigil holds no assertions of its own, so nothing else is left behind."
echo "If you added it as a login item, remove it under"
echo "System Settings > General > Login Items."
