#!/bin/bash

shopt -s dotglob # Enable matching hidden files

directory="/home/{{ runner_user }}"
exclusions=({% for item in runner_post_run_exclusions %}
	"{{ item }}"{% if not loop.last %} {% endif %}
	{% endfor %}) # Any file/directory that matches this list will not be touched

delete_failed=false # Variable to track if any delete operations fail

# Function to delete files with a retry mechanism
delete_with_backoff() {
	local target="$1"
	local retries=5
	local delay=5
	local attempt=1

	while [[ $attempt -le $retries ]]; do
		if sudo rm -rf "$target"; then
			echo "Successfully deleted $target"
			break
		else
			echo "Failed to delete $target, retrying in $delay seconds (Attempt $attempt/$retries)"
			sleep $delay
			# Exponentially increasing the delay
			delay=$((delay * 2))
		fi
		attempt=$((attempt + 1))
	done

	if [[ $attempt -gt $retries ]]; then
		echo "Failed to delete $target after $retries attempts."
		delete_failed=true # Set the global failure variable to true
	fi
}

for file in "$directory"/*; do
	filename=$(basename "$file")
	if [[ ! "${exclusions[*]}" =~ $filename ]]; then
		delete_with_backoff "$directory/$filename"
	fi
done

# Check if any delete operations failed, and exit with code 1 if so
if $delete_failed; then
	echo "One or more delete operations failed."
	exit 1
else
	echo "All delete operations completed successfully."
	exit 0
fi
