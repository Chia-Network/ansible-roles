#!/bin/bash
set -o pipefail
CHIA_PATH="/home/{{ user }}/chia-blockchain"

if [ -d "$CHIA_PATH" ]; then
    echo "Found $CHIA_PATH — activating environment..."
    . "$CHIA_PATH/activate"
else
    echo "$CHIA_PATH not found — Chia is installed with apt. Continuing...."
fi

# Set log level to DEBUG, wait, then revert to INFO
chia configure --log-level DEBUG
echo "Log level set to DEBUG. Restarting chia services...."
sudo systemctl restart chia.target
sleep 1
chia configure --log-level INFO
echo "Log level set to INFO. Restarting chia services...."
sudo systemctl restart chia.target
