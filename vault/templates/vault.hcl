# Full configuration options can be found at https://www.vaultproject.io/docs/configuration

ui = true

storage "consul" {
  address = "127.0.0.1:8500"
  path    = "vault/"
  token   = "{{ vault_consul_token }}"
}

# HTTPS listener
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "{{ vault_tls_cert }}"
  tls_key_file  = "{{ vault_tls_key }}"
}
