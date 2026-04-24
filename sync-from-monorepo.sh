#!/bin/bash
# Sync LunaAnimator monorepo → luna-runtime source
# Run if you made changes directly in the monorepo that need to come back

MONO=~/Documents/LunaAnimator/src/Luna
SRC=~/Documents/luna-runtime/src

cp -r "$MONO/Core/"* "$SRC/Core/"
cp -r "$MONO/Solver/"* "$SRC/Solver/"
cp -r "$MONO/Types/"* "$SRC/Types/"
cp -r "$MONO/Shared/"* "$SRC/Shared/"

echo "Synced LunaAnimator → luna-runtime"
