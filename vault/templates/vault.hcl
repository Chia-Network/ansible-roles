# Full configuration options can be found at https://www.vaultproject.io/docs/configuration

ui = true
disable_mlock = true
api_addr = "{{ vault_api_addr }}"
cluster_addr = "{{ vault_cluster_addr }}"

storage "raft" {
  path = "{{ vault_data_path }}"
  node_id = "{{ vault_node_id }}"

{% for other_node in vault_other_node_addresses %}
  retry_join {
    leader_api_addr = "{{ other_node }}"
  }
{% endfor %}
}

# HTTPS listener
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "{{ vault_tls_cert }}"
  tls_key_file  = "{{ vault_tls_key }}"
}
