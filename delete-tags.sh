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

echo "Starting deletion of remote tags in batches..."
batch_size=100
counter=0
batch_counter=0

# Process tags in batches
while IFS= read -r tag; do
    tags_batch+=("$tag")
    counter=$((counter + 1))
    
    # When we reach batch size or end of file, delete the batch
    if (( ${#tags_batch[@]} >= batch_size )) || (( counter >= total_tags )); then
        batch_counter=$((batch_counter + 1))
        echo "[$counter/$total_tags] Deleting batch $batch_counter (${#tags_batch[@]} tags)..."
        
        # Build the push command with all tags in this batch
        push_args=()
        for tag in "${tags_batch[@]}"; do
            push_args+=(":refs/tags/$tag")
        done
        
        git push origin "${push_args[@]}"
        tags_batch=()
        
        # Brief pause between batches
        sleep 0.5
    fi
done < all_remote_tags.txt

echo "Completed deleting $counter remote tags in batches"
