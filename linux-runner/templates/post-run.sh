#!/bin/bash

echo "[INFO] Stopping any running docker containers"

# Get all container IDs (running or not)
CONTAINERS=$(docker ps -aq) || CONTAINERS=""

if [ -n "$CONTAINERS" ]; then
  echo "[INFO] Found containers: $CONTAINERS"

  # Stop containers, ignore any individual failure
  docker stop $CONTAINERS || true

  # Remove containers, ignore failure (e.g., already removed)
  docker rm -f $CONTAINERS || true
else
  echo "[INFO] No containers to stop/remove"
fi

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

if [ -n "${GITHUB_WORKSPACE}" ]; then
	parent=$(dirname "$GITHUB_WORKSPACE")
	delete_with_backoff "$parent"
fi

sudo rm -rf "/home/{{ runner_user }}/actions-runner/_work" || true
sudo rm -rf /tmp/* || true

# Reset the docker auth if we have a template
if [ -f "${directory}/.docker/config.json.tmpl" ]; then
	rm "${directory}/.docker/config.json" || true
	cp "${directory}/.docker/config.json.tmpl" "${directory}/.docker/config.json"
fi

# Check if any delete operations failed, and exit with code 1 if so
if $delete_failed; then
	echo "One or more delete operations failed."
	exit 1
else
	echo "All delete operations completed successfully."
	exit 0
fi
