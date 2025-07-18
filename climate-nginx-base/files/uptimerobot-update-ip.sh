#!/bin/bash

# Script to download UptimeRobot IP addresses and create nginx allow list
# Based on cloudflare-update-ip-ranges.sh pattern

# Stop if any error occurs
set -ex

# Location of the nginx config file that contains the UptimeRobot IP addresses.
UPTIMEROBOT_NGINX_CONFIG="/etc/nginx/conf.d/0-uptimerobot-ips.conf"

# Create a unique temporary file with proper permissions
UPTIMEROBOT_NGINX_TMP=$(mktemp /tmp/uptimerobot_tmp.XXXXXX)

# Ensure temp file is cleaned up on exit
trap "rm -f $UPTIMEROBOT_NGINX_TMP" EXIT

# The URL with the actual IP addresses used by UptimeRobot.
UPTIMEROBOT_URL="https://cdn.uptimerobot.com/api/IPv4andIPv6.txt"

# Start with an empty file (mktemp already creates it empty, but being explicit)
>$UPTIMEROBOT_NGINX_TMP

# Download the file.
if [ -f /usr/bin/curl ]; then
        echo "# UptimeRobot IP addresses for allow list" >>$UPTIMEROBOT_NGINX_TMP
        echo "# Downloaded from: $UPTIMEROBOT_URL" >>$UPTIMEROBOT_NGINX_TMP
        echo "# Generated on: $(date)" >>$UPTIMEROBOT_NGINX_TMP
        echo "" >>$UPTIMEROBOT_NGINX_TMP

        # Download and process the IP addresses
        # Each IP is converted to an allow directive
        curl --silent $UPTIMEROBOT_URL | sed -e 's/^[[:space:]]*\([^[:space:]]\+\)[[:space:]]*$/allow \1;/' | grep -v '^allow[[:space:]]*;$' >>$UPTIMEROBOT_NGINX_TMP
else
        echo "Unable to download UptimeRobot files - curl not found."
        exit 1
fi

mv -f $UPTIMEROBOT_NGINX_TMP $UPTIMEROBOT_NGINX_CONFIG

# Reload Nginx
if sudo nginx -t &>/dev/null; then
        echo "Nginx configuration test successful. Restarting Nginx..."
        # Restart Nginx service
        sudo systemctl reload nginx
        echo "Nginx reloaded."
else
        echo "Nginx configuration test failed. Nginx will not be restarted."
        # Optionally, you can add error handling or logging here
        # For example, print the Nginx test output to stderr for debugging
        sudo nginx -t
fi
