#!/bin/bash

cp -r /home/{{ user }}/.chia/config/ssl/ca /home/{{ user }}/ca
rm -rf /home/{{ user }}/.chia/config/ssl

export PATH="/home/{{ user }}/chia-blockchain/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export CHIA_ROOT="{{ chia_root }}"
chia init -c /home/{{ user }}/ca

rm -rf /home/{{ user }}/ca

chown -R {{ user }}:{{ group }} /home/{{ user }}/.chia

sudo systemctl restart chia.target
