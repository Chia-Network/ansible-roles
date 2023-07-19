#!/bin/bash

shopt -s dotglob # Enable matching hidden files

directory="/home/{{ runner_user }}"
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
