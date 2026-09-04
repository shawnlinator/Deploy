storage "raft" {
  path    = "/openbao/file"
  node_id = "node1"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  # TODO: before exposing this beyond localhost, replace tls_disable with a
  # real cert/key pair (tls_cert_file / tls_key_file), e.g. behind a
  # TLS-terminating reverse proxy or with certs from an internal CA.
  tls_disable = "true"
}

# OpenBao removed mlock support entirely (as of 2.6.x, confirmed against a
# live 2.6.2 container) — it now refuses to start if "disable_mlock" is set
# at all, in either direction. Swap protection is handled at the container
# level instead: see docker-compose.yml's mem_limit/memswap_limit and
# Plan.md's Docker/swap section.

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"

ui = true
