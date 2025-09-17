#!/bin/bash

shopt -s dotglob # Enable matching hidden files

directory="/Users/{{ runner_user }}"
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

sudo rm -rf "/Users/{{ runner_user }}/actions-runner/_work" || true

# relevant to https://github.com/Apple-Actions/import-codesign-certs
security delete-keychain signing_temp.keychain || true
# https://github.com/Chia-Network/chia-blockchain/blob/d67a7df84cc22179497df037aa5caee65fb14cbb/.github/workflows/test-single.yml#L151
security delete-keychain chiachain || true

# Clean up old globally installed node_modules that might conflict with the current build
rm -rf /opt/homebrew/lib/node_modules || true

# Clean up any installed versions of node so we can start fresh
cd $HOME
brew list | grep "^node\@\|^node$" | xargs -L1 brew uninstall || true
brew cleanup -s
brew_directory="/Users/{{ runner_user }}/Library/Caches/Homebrew/downloads"
for file in "$brew_directory"/*; do
	filename=$(basename "$file")
	delete_with_backoff "$brew_directory/$filename"
done

# Check if any delete operations failed, and exit with code 1 if so
if $delete_failed; then
	echo "One or more delete operations failed."
	exit 1
else
	echo "All delete operations completed successfully."
	exit 0
fi
