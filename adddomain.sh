#!/bin/sh

# Backwards-compatible wrapper. Domain lifecycle is now managed by emailwizctl.
exec emailwizctl domain add "$@"
