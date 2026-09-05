#!/bin/sh
# Retrieves the SoftHSM token's login PIN by unsealing it from this
# machine's TPM, then execs the real server. The PIN
# itself is never written to disk in plaintext anywhere — it only ever
# exists as this process's environment variable, reconstructed fresh from
# the TPM-sealed blob on every start. If the vTPM is missing, migrated, or
# this isn't the same machine, tpm2_unseal fails and startup aborts here.
set -eu

export SOFTHSM2_CONF=/etc/softhsm2.conf

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

TCTI="device:/dev/tpmrm0"

tpm2_createprimary -T "$TCTI" -C o -G rsa2048 -c "$TMPDIR/primary.ctx" >/dev/null
tpm2_load -T "$TCTI" -C "$TMPDIR/primary.ctx" \
  -u /etc/openbao/tpm/pin.pub \
  -r /etc/openbao/tpm/pin.priv \
  -c "$TMPDIR/pin.ctx" >/dev/null

BAO_HSM_PIN="$(tpm2_unseal -T "$TCTI" -c "$TMPDIR/pin.ctx")"
export BAO_HSM_PIN

exec bao server -config=/openbao/config
