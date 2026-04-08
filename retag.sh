#!/usr/bin/env bash
set -euo pipefail

ORIGIN_URL="git@github.com:yaml/go-yaml.git"
FORK_URL="git@github.com:go-yaml-in/yaml.git"

# Configure GPG for non-interactive signing (no passphrase)
mkdir -p ~/.gnupg
echo "pinentry-mode loopback" >> ~/.gnupg/gpg.conf
echo "allow-loopback-pinentry" >> ~/.gnupg/gpg-agent.conf
gpgconf --kill gpg-agent 2>/dev/null || true

tmpdir=$(mktemp -d)
echo "Cloning into $tmpdir..."

cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

git clone --quiet "$ORIGIN_URL" "$tmpdir"
cd "$tmpdir"
git config user.name "go-yaml"
git config user.email "yaml@go-yaml.in"
git remote add fork "$FORK_URL"
# Fetch fork tags into a separate namespace to avoid collisions with origin tags
git fetch --quiet fork '+refs/tags/*:refs/fork-tags/*'

for tag in $(git tag); do
    # Skip tags already retagged in fork
    fork_commit=$(git rev-list -n1 "refs/fork-tags/$tag" 2>/dev/null || true)
    if [[ -n "$fork_commit" ]]; then
        fork_email=$(git log --format='%ae' -1 "$fork_commit")
        if [[ "$fork_email" == "yaml@go-yaml.in" ]]; then
            echo "Skipping $tag (already retagged in fork)"
            continue
        fi
    fi

    commit=$(git rev-list -n1 "$tag")
    author_email=$(git log --format='%ae' -1 "$commit")

    if [[ "$author_email" == "yaml@go-yaml.in" ]]; then
        echo "Skipping $tag (author: $author_email)"
        continue
    fi

    echo "Processing $tag (commit $commit, author: $author_email)..."

    git checkout "$commit" --detach --quiet

    # Replace go.yaml.in with go-yaml.in in all files (skip .git)
    find . -not -path './.git/*' -type f -exec \
        sed -i 's/go\.yaml\.in/go-yaml.in/g' {} +

    # Check if there are any changes
    if git diff --quiet; then
        echo "  No changes for $tag, skipping"
        continue
    fi

    git add -A
    git commit --quiet -S -m "go-yaml.in $tag" --author="go-yaml <yaml@go-yaml.in>"

    new_commit=$(git rev-parse HEAD)

    # Delete old tag and create new one pointing to new commit
    git tag -d "$tag" >/dev/null
    git tag -s "$tag" "$new_commit" -m "$tag"

    # Push the commit (to a temporary branch) and force-push the tag
    git push fork "$new_commit:refs/heads/_retag_tmp" --quiet
    git push fork "$tag" --force --quiet
    git push fork --delete _retag_tmp --quiet 2>/dev/null || true

    echo "  Done: $tag -> $new_commit"
done

echo "All tags processed."
