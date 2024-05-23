#!/bin/bash

shopt -s dotglob # Enable matching hidden files

directory="/Users/{{ runner_user }}"
exclusions=({% for item in runner_post_run_exclusions %}
	"{{ item }}"{% if not loop.last %} {% endif %}
	{% endfor %}) # Any file/directory that matches this list will not be touched

for file in "$directory"/*; do
	filename=$(basename "$file")
	if [[ ! "${exclusions[*]}" =~ $filename ]]; then
		sudo rm -rf "$directory/$filename"
	fi
done

if [ -n "${GITHUB_WORKSPACE}" ]; then
	parent=$(dirname "$GITHUB_WORKSPACE")
	sudo rm -rf "$parent"
fi

sudo rm -rf "/Users/{{ runner_user }}/actions-runner/_work" || true

# relevant to https://github.com/Apple-Actions/import-codesign-certs
security delete-keychain signing_temp.keychain || true

# Clean up old globally installed node_modules that might conflict with the current build
rm -rf /opt/homebrew/lib/node_modules || true

# Clean up any installed versions of node so we can start fresh
brew list | grep "^node\@\|^node$" | xargs -L1 brew uninstall || true
