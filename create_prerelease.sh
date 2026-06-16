#!/bin/bash

set -e

if [ -n "$(git status --porcelain)" ]; then
    echo "Error: There are unstaged or staged changes. Commit or stash them first."
    exit 1
fi

if [ "$(git rev-list HEAD --not --remotes)" != "" ]; then
    echo "Error: There are local commits that have not been pushed to a remote."
    exit 1
fi

echo "Running tests..."
zig build test
bun test
echo "Tests passed!"

git fetch --tags >/dev/null 2>&1

LAST_TAG=$(git tag -l "v*" | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z]+\.[0-9]+)?$" | sort -V | tail -n1)

if [ -z "$LAST_TAG" ]; then
    NEW_TAG="v0.1.0-alpha.1"
    echo "No existing tags found. Starting with default."
else
    echo "Current latest tag: $LAST_TAG"

    if [[ $LAST_TAG =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-([a-zA-Z]+)\.([0-9]+)$ ]]; then
        MAJOR="${BASH_REMATCH[1]}"
        MINOR="${BASH_REMATCH[2]}"
        PATCH="${BASH_REMATCH[3]}"
        SUFFIX="${BASH_REMATCH[4]}"
        NUM="${BASH_REMATCH[5]}"

        NEXT_NUM=$((NUM + 1))
        NEW_TAG="v$MAJOR.$MINOR.$PATCH-$SUFFIX.$NEXT_NUM"
    elif [[ $LAST_TAG =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        MAJOR="${BASH_REMATCH[1]}"
        MINOR="${BASH_REMATCH[2]}"
        PATCH="${BASH_REMATCH[3]}"

        NEXT_PATCH=$((PATCH + 1))
        NEW_TAG="v$MAJOR.$MINOR.$NEXT_PATCH-alpha.1"
    else
        echo "Error: Latest tag format '$LAST_TAG' not recognized. Expected standard semver (e.g. v1.2.3 or v1.2.3-beta.1)"
        exit 1
    fi
fi

echo "----------------------------------------"
echo "  Detected Latest: $LAST_TAG"
echo "  Proposed Next:   $NEW_TAG"
echo "----------------------------------------"

read -p "Create and push tag $NEW_TAG? (y/N) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    git tag -a "$NEW_TAG" -m "Pre-release $NEW_TAG"
    git push origin "$NEW_TAG"
    echo "Tag $NEW_TAG created and pushed!"
else
    echo "Aborted."
    exit 0
fi