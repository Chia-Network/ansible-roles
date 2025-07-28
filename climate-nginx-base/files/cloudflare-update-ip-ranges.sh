#!/bin/bash

# From https://gist.github.com/dcampos/b4f4308d333e5c57e36ec7a329a7b37a

# Stop if any error occurs
set -ex

# Location of the nginx config file that contains the CloudFlare IP addresses.
CF_NGINX_CONFIG="/etc/nginx/conf.d/cloudflare.conf"
CF_NGINX_TMP="/tmp/cloudflare_tmp.conf"

# The URLs with the actual IP addresses used by CloudFlare.
CF_URL_IP4="https://www.cloudflare.com/ips-v4"
CF_URL_IP6="https://www.cloudflare.com/ips-v6"

truncate -s 0 $CF_NGINX_TMP

# Download the files.
if [ -f /usr/bin/curl ]; then
	echo "# IPv4" >>$CF_NGINX_TMP
	curl --silent $CF_URL_IP4 | sed -e 's/^.\+$/set_real_ip_from \0;/' >>$CF_NGINX_TMP
	echo "" >>$CF_NGINX_TMP
	echo "# IPv6" >>$CF_NGINX_TMP
	curl --silent $CF_URL_IP6 | sed -e 's/^.\+$/set_real_ip_from \0;/' >>$CF_NGINX_TMP
else
	echo "Unable to download CloudFlare files."
	exit 1
fi

echo "" >>$CF_NGINX_TMP
echo "real_ip_header CF-Connecting-IP;" >>$CF_NGINX_TMP

echo "" >>$CF_NGINX_TMP
echo "# Ignore trusted IPs" >>$CF_NGINX_TMP
echo "real_ip_recursive on;" >>$CF_NGINX_TMP

mv $CF_NGINX_TMP $CF_NGINX_CONFIG

chmod 644 $CF_NGINX_CONFIG

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
