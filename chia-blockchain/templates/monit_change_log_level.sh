#!/bin/bash
set -o pipefail
CHIA_PATH="/home/{{ user }}/chia-blockchain"

if [ -d "$CHIA_PATH" ]; then
		echo "Found $CHIA_PATH — activating environment..."
		# shellcheck disable=SC1091
		. "$CHIA_PATH/activate"
		# shellcheck enable=SC1091
else
		echo "$CHIA_PATH not found — Chia is installed with apt. Continuing...."
fi

# Set log level to DEBUG, wait, then revert to INFO
chia rpc full_node set_log_level '{ "level": "DEBUG" }'
chia rpc timelord set_log_level '{ "level": "DEBUG" }'
echo "Log level set to DEBUG. Sleeping for 1 minute...."
sleep 1
chia rpc full_node set_log_level '{ "level": "INFO" }'
chia rpc timelord set_log_level '{ "level": "INFO" }'
echo "Log level set back to INFO"
