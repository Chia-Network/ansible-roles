# Base Setup

Applies some common settings to all systems.

## Variables

| Variable                                | Default                       | Description                                                            |
| --------------------------------------- | ----------------------------- | ---------------------------------------------------------------------- |
| `base_setup_disable_ssh_password_login` | `true`                        | When true, sets `PasswordAuthentication no` in `/etc/ssh/sshd_config`. |
| `base_setup_disable_ssh_root_login`     | `true`                        | When true, sets `PermitRootLogin no` in `/etc/ssh/sshd_config`.        |
| `base_setup_ssh_login`                  | `{{ ansible_user }}`          | Darwin only: account whose authorized key is checked before passwords are disabled. |

## Darwin

On macOS the role also sets `KbdInteractiveAuthentication no`, validates the
result with `/usr/sbin/sshd -t`, and restarts launchd's `com.openssh.sshd`
instead of a systemd `ssh` unit. Before disabling password authentication it
refuses to continue unless the login account already has a non-empty
`~/.ssh/authorized_keys`, so a misconfigured run cannot lock out the controller.
