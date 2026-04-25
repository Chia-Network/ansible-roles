# Base Setup

Applies some common settings to all systems

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `base_setup_disable_ssh_password_login` | `true` | When true, sets `PasswordAuthentication no` in `/etc/ssh/sshd_config`. |
| `base_setup_disable_ssh_root_login` | `true` | When true, sets `PermitRootLogin no` in `/etc/ssh/sshd_config`. |
