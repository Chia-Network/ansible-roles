# Alloy

Installs and configures [Grafana Alloy](https://grafana.com/oss/alloy/) on Debian/Ubuntu hosts to ship logs to a Loki endpoint.

The role includes opt-out scrape configs for syslog, fail2ban, and Chia logs.
Disable any of them with the `alloy_enable_*_source` flags below. You can also
add arbitrary log files, inject raw Alloy config, or deploy extra snippet files
for full flexibility.

## Requirements

- Debian / Ubuntu target host
- A reachable Loki push endpoint

## Role Variables

### Alloy core

| Variable | Default | Description |
|---|---|---|
| `alloy_log_level` | `info` | Alloy log level (`debug`, `info`, `warn`, `error`). |
| `alloy_log_format` | `logfmt` | Alloy log format (`logfmt` or `json`). |
| `alloy_user_groups` | `[adm, systemd-journal, ubuntu]` | Supplementary groups granted to the `alloy` user so it can read log files. |
| `alloy_start_on_boot` | `true` | Whether the systemd unit is enabled at boot. |
| `alloy_start_now` | `true` | Start the service immediately (`true`) or leave it stopped (`false`). |

### Loki

| Variable | Default | Description |
|---|---|---|
| `loki_endpoint` | `""` | Loki push API URL (e.g. `https://loki.example.com/loki/api/v1/push`). |
| `loki_basic_auth_username` | `""` | Optional basic-auth username. |
| `loki_basic_auth_password` | `""` | Optional basic-auth password. |

### Built-in log sources

All built-in sources are opt-out. Set the corresponding flag to `false` to
exclude the source in the generated config.

| Variable | Default | Description |
|---|---------|---|
| `alloy_enable_syslog_source` | `true`  | Ship `/var/log/syslog` to Loki. |
| `alloy_enable_fail2ban_source` | `true` | Ship `/var/log/fail2ban.log` to Loki. |
| `alloy_enable_chia_source` | `true` | Ship Chia debug logs (with multiline + JSON processing). |

### Chia

These are applied to the Chia log source and are only relevant when
`alloy_enable_chia_source` is `true`.

| Variable | Default | Description |
|---|---|---|
| `chia_root` | `/home/ubuntu/.chia` | Path to the Chia root directory. |
| `application` | `chia-blockchain` | `application` label. |
| `component` | `node` | `component` label. |
| `network` | `mainnet` | `network` label. |
| `group_tag` | `default` | `group` label. |
| `repo_ref` | `""` | `ref` label (e.g. a git ref). |

### Extensibility

| Variable | Default | Description |
|---|---|---|
| `alloy_extra_log_files` | `[]` | List of additional log files to ship (see below). |
| `alloy_extra_config` | `""` | Raw Alloy (River) config appended to the end of the generated file. |
| `alloy_additional_files` | `[]` | Extra snippet files deployed to `/etc/alloy/` (see below). |

## Usage Examples

### Minimal – just ship syslog to Loki

```yaml
- hosts: all
  roles:
    - role: alloy
      loki_endpoint: "https://loki.example.com/loki/api/v1/push"
```

### Loki with basic auth

```yaml
- hosts: all
  roles:
    - role: alloy
      loki_endpoint: "https://loki.example.com/loki/api/v1/push"
      loki_basic_auth_username: "{{ vault_loki_user }}"
      loki_basic_auth_password: "{{ vault_loki_pass }}"
```

### Chia with custom labels

```yaml
- hosts: chia_hosts
  roles:
    - role: alloy
      loki_endpoint: "https://loki.example.com/loki/api/v1/push"
      application: chia-blockchain
      component: farmer
      network: testnet11
      group_tag: us-east-farm
      repo_ref: "v2.7.0"
      chia_root: /opt/chia/.chia
```

### Ship additional log files

Use `alloy_extra_log_files` to add arbitrary log sources. Each entry creates
its own `loki.source.file` component forwarding to the default Loki sink.

```yaml
- hosts: app_servers
  roles:
    - role: alloy
      loki_endpoint: "https://loki.example.com/loki/api/v1/push"
      alloy_extra_log_files:
        - name: nginx_access
          path: /var/log/nginx/access.log
          job: nginx          # optional – defaults to name
          extra_labels:        # optional
            environment: production
            tier: frontend

        - name: myapp
          path: /opt/myapp/logs/app.log
          extra_labels:
            service: myapp
```

### Inject raw Alloy config

For components not covered by the built-in scrape targets, append arbitrary
River config with `alloy_extra_config`.

```yaml
- hosts: all
  roles:
    - role: alloy
      loki_endpoint: "https://loki.example.com/loki/api/v1/push"
      alloy_extra_config: |
        prometheus.scrape "node" {
          targets    = [{"__address__" = "localhost:9100"}]
          forward_to = [prometheus.remote_write.default.receiver]
        }

        prometheus.remote_write "default" {
          endpoint {
            url = "https://mimir.example.com/api/v1/push"
          }
        }
```

### Deploy extra snippet files + import them

For larger config blocks, deploy them as separate files with
`alloy_additional_files` and pull them in via `alloy_extra_config`.

```yaml
- hosts: all
  roles:
    - role: alloy
      loki_endpoint: "https://loki.example.com/loki/api/v1/push"

      alloy_additional_files:
        - path: /etc/alloy/metrics.alloy
          content: |
            prometheus.scrape "node" {
              targets    = [{"__address__" = "localhost:9100"}]
              forward_to = [prometheus.remote_write.default.receiver]
            }

            prometheus.remote_write "default" {
              endpoint {
                url = "https://mimir.example.com/api/v1/push"
              }
            }

      alloy_extra_config: |
        import.file "metrics" {
          filename = "/etc/alloy/metrics.alloy"
        }
```

### Install but don't start

Useful for baking images (AMIs, etc.) where the service should only start once
the machine is fully provisioned.

```yaml
- hosts: packer_builders
  roles:
    - role: alloy
      loki_endpoint: "https://loki.example.com/loki/api/v1/push"
      alloy_start_now: false
      alloy_start_on_boot: true
```

### Grant extra groups for log access

If your application writes logs as a specific group, add that group so the
`alloy` user can read them.

```yaml
- hosts: app_servers
  roles:
    - role: alloy
      loki_endpoint: "https://loki.example.com/loki/api/v1/push"
      alloy_user_groups:
        - adm
        - systemd-journal
        - ubuntu
        - myapp-logs
```

## What Gets Deployed

| Path | Description |
|---|---|
| `/etc/alloy/config.alloy` | Main Alloy configuration (templated). |
| `/etc/alloy/*.alloy` | Any additional snippet files from `alloy_additional_files`. |
| `/usr/share/keyrings/grafana.gpg` | Grafana APT signing key. |

The role enables the `alloy` systemd unit and (by default) starts it
immediately. A handler restarts the service whenever the config or snippet
files change.

## Built-in Log Sources

The role can generate `loki.source.file` components for these log files. Each
is opt-out (enabled by default) via the corresponding flag.

| Name | Enable flag | Path | Job label |
|---|---|---|---|
| `syslog` | `alloy_enable_syslog_source` | `/var/log/syslog` | `syslog` |
| `fail2ban` | `alloy_enable_fail2ban_source` | `/var/log/fail2ban.log` | `fail2ban` |
| `chia` | `alloy_enable_chia_source` | `{{ chia_root }}/log/debug.log` | `chia` |

The Chia source passes through a `loki.process` stage that handles multiline
log entries and JSON field extraction before forwarding to Loki.
