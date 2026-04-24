#!/bin/bash
# Sync luna-runtime source → LunaAnimator monorepo
# Run after making changes in luna-runtime that you want to test in Studio

MONO=~/Documents/LunaAnimator/src/Luna
SRC=~/Documents/luna-runtime/src

cp -r "$SRC/Core/"* "$MONO/Core/"
cp -r "$SRC/Solver/"* "$MONO/Solver/"
cp -r "$SRC/Types/"* "$MONO/Types/"
cp -r "$SRC/Shared/"* "$MONO/Shared/"

echo "Synced luna-runtime → LunaAnimator"
