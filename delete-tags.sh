#!/bin/bash
set -euo pipefail

echo "Fetching all remote tags..."
git ls-remote --tags --sort=-committerdate --tags origin | cut -f2 | sed 's/refs\/tags\///' | sed 's/\^{}//' > all_remote_tags.txt

total_tags=$(wc -l < all_remote_tags.txt)
echo "Found $total_tags remote tags to delete"

read -p "Are you sure you want to delete all $total_tags remote tags? This cannot be undone! (type 'yes' to confirm): " confirm
if [[ $confirm != "yes" ]]; then
    echo "Operation cancelled."
    rm all_remote_tags.txt
    exit 1
fi

echo "Starting deletion of remote tags..."
counter=0
while IFS= read -r tag; do
    counter=$((counter + 1))
    echo "[$counter/$total_tags] Deleting remote tag: $tag"
    git push origin --delete "$tag"
    
    # Add a small delay every 100 deletions to avoid overwhelming the server
    if (( counter % 100 == 0 )); then
        echo "  Pausing briefly..."
        sleep 1
    fi
done < all_remote_tags.txt

echo "Completed deleting $counter remote tags"
