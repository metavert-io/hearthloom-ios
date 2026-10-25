#!/bin/sh
# Regenerate Hearthloom.xcodeproj from project.yml, layering in any opt-in
# feature overlays that are present locally.
#
# Feature overlays (all gitignored, all optional):
#   project.sentry.yml  → compiles in Sentry APM + sets the SENTRY_DSN build
#                         setting. Copy project.sentry.yml.example to enable.
#
# With no overlays present this is equivalent to a plain `xcodegen generate`,
# so a fresh clone builds clean with none of the optional features.
set -e
cd "$(dirname "$0")/.."

OVERLAYS=""
[ -f project.sentry.yml ] && OVERLAYS="$OVERLAYS project.sentry.yml"

if [ -n "$OVERLAYS" ]; then
  echo "→ Generating WITH overlays:$OVERLAYS"
  {
    echo "name: Hearthloom"
    echo "include:"
    echo "  - project.yml"
    for f in $OVERLAYS; do echo "  - $f"; done
  } > .xcodegen-composed.yml
  xcodegen generate --spec .xcodegen-composed.yml
  rm -f .xcodegen-composed.yml
else
  echo "→ Generating WITHOUT optional overlays (default)."
  xcodegen generate --spec project.yml
fi
