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

# TPM-gated auto-unseal: the real AES-256 seal key lives in a SoftHSM2
# token (persisted in the softhsm-tokens volume); the token's login PIN is
# never stored in plaintext, only as a blob sealed to this host's TPM,
# unsealed fresh on every start by entrypoint-tpm.sh and passed via the
# BAO_HSM_PIN env var. See Plan.md's TPM auto-unseal section.
seal "pkcs11" {
  lib         = "/usr/lib/softhsm/libsofthsm2.so"
  token_label = "openbao-token"
  key_label   = "openbao-unseal-key"
  mechanism   = "0x1087" # CKM_AES_GCM
  pin         = "env://BAO_HSM_PIN"
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"

ui = true
