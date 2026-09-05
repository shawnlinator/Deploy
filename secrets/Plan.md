# Secrets management plan (AI-assistant-aware threat model)

## Threat model

Any coding assistant with shell/file access (Claude Code included) should be treated as
having read access to everything in a project it operates on. Once a secret is on disk as
plaintext, it can end up in the assistant's conversation context, session transcripts, and
logs — regardless of `.gitignore` or permission "deny" rules layered on top.

This isn't hypothetical for Claude Code specifically: `permissions.read.deny` rules in
`settings.json` are documented as unreliably enforced ([anthropics/claude-code#24846](https://github.com/anthropics/claude-code/issues/24846)),
and even a working deny rule only blocks the `Read` tool — a `cat .env` or a small script run
through `Bash` routes around it entirely ([source](https://eve.gd/2026/04/19/claude-code-can-consume-transmit-and-compromise-your-env-files-even-if-you-tell-it-not-to/)).

**Design principle:** don't try to fence the assistant out of secrets after the fact — make
sure there's no plaintext secret sitting on disk for it to find in the first place.

## Plan

1. **No static plaintext secrets in the repo, ever.**
   - No `.env` files with real values committed or left checked out during agent sessions.
   - `.gitignore` covers `.env*`, `*.pem`, `*.key`, `secrets/`, `credentials/` — as a backstop,
     not the primary control.

2. **Runtime-injected secrets from a vault, not files.**
   - Use a secrets manager (HashiCorp Vault, AWS/Azure/OCI Secrets Manager, Doppler, or
     Infisical depending on where this deploys) to inject credentials directly into the
     process environment at startup.
   - Nothing decrypts to a plaintext file on disk that an agent (or anything else) can read.
   - **FOSS + self-hosted pick: [OpenBao](https://github.com/openbao/openbao).** HashiCorp
     Vault moved to BUSL in 2023 (not OSI-approved, and the license restricts hosting it as a
     competing service); OpenBao is the Linux Foundation/OpenSSF-governed Apache-2.0 fork that
     kept the same API and secrets-engine model, so it drops into the rest of this plan
     directly. Infisical (MIT, Docker self-host, nicer UI) is a reasonable alternative but is
     open-core, so some features may push toward its paid tier.

3. **Short-lived, dynamic credentials over static keys.**
   - Prefer Vault dynamic secrets / cloud STS-style temporary credentials with short TTLs
     (minutes–hours) over long-lived static API keys.
   - If a credential does leak into a transcript, log, or context window, its useful window
     is small and it expires on its own.

4. **Keep the agent out of the secret's path structurally.**
   - Where an agent orchestrates an action that needs a credential (calling an API, deploying,
     etc.), resolve the actual secret value in a separate execution handler right before use —
     not in a step the agent's context passes through.
   - The agent should be able to *cause* an authenticated action without ever seeing the
     credential that authenticated it.

5. **Local dev: encrypted/keychain-backed store, not a plaintext `.env`.**
   - 1Password Environments (virtual `.env`, mounted in-memory, hardware-key gated),
     `aws-vault`, `git-credential-manager`, or the OS keychain.
   - Goal: no plaintext credential file ever exists on the dev machine's filesystem, even
     transiently.

6. **Claude Code permission deny rules: defense-in-depth only.**
   - Still set `permissions.read.deny` in `settings.json` for `**/.env*`, `**/*.pem`,
     `**/*.key`, `**/.ssh/**`, `**/.aws/**`, `**/secrets/**`, `**/credentials/**`.
   - Treat this as blocking *accidental* reads, not as a security boundary — it does not hold
     up against `Bash`-based access or determined bypass.

7. **Secret-scanning as a backstop, not prevention.**
   - Pre-commit and CI scanning with `gitleaks` / `trufflehog` / `detect-secrets`, plus GitHub
     push protection, to catch anything that lands in git history despite the above.
   - This limits damage after the fact; it isn't a substitute for keeping secrets out of files
     in the first place.

## Implementation notes: OpenBao on Docker

Running OpenBao itself in a container raises the same "don't let secrets touch disk"
question one layer down — this time about process memory and swap, not files.

- **`mlock` is gone — verified against a running container, not just docs.** OpenBao dropped
  `mlock` support entirely as of 2.6.x; a live `openbao/openbao:2.6.2` container refuses to
  start if `disable_mlock` is set at all, in either direction, and errors with "OpenBao has
  dropped support for mlock ... disable or encrypt swap instead." So `CAP_IPC_LOCK` and a
  raised `memlock` ulimit — this plan's original mitigation — buy nothing on current versions;
  don't bother granting the capability. Swap has to be handled entirely at the container/host
  level now, which is what the next point does.

- **Decision: deny the OpenBao container swap entirely via cgroups, rather than encrypting
  host swap.** Swap isn't namespaced per container — `swapon` registers a device/file for the
  whole host, shared by every container — so there's no way to give just OpenBao its own
  encrypted swap volume. Setting the cgroup swap limit equal to the memory limit removes the
  question instead of mitigating it: there's no swap for this container to use, encrypted or
  not. In `docker-compose.yml` ([openbao/docker-compose.yml](openbao/docker-compose.yml)):
  ```yaml
  cap_drop: ["ALL"]        # no capabilities needed now that mlock is gone
  mem_limit: 1g
  memswap_limit: 1g        # equal to mem_limit => zero swap headroom
  ```
  Verified live: `docker inspect openbao` shows `Memory=1073741824
  MemorySwap=1073741824` after `docker compose up`, and the container starts and serves
  `/v1/sys/health` cleanly with `cap_drop: ALL` and no added capabilities.
  - Equal `mem_limit`/`memswap_limit` means the container gets OOM-killed rather than
    swapped if it exceeds the limit — the right failure mode for a secrets-manager container.
  - Size `mem_limit` for worst-case, not steady-state: Raft's storage engine (bbolt) mmaps
    its entire database file, and with mlock gone there's no guarantee those pages stay
    resident, but there's also no swap for them to spill into if the container grows past the
    limit — it gets killed, not degraded. Size against projected data volume with headroom,
    and monitor container memory usage as the vault's contents grow.
  - This makes host-level swap encryption unnecessary *for this container* — OpenBao simply
    never touches host swap. Encrypting host swap is still worth doing independently if other
    processes on the same host handle sensitive data, but it's no longer this plan's control
    for OpenBao specifically.

- **Rootless Docker hosts: don't bother trying to raise `memlock` ulimits.** Moot now that
  mlock is gone, but worth remembering for other containers: on a rootless Docker host, a
  container can't set a `memlock` ulimit above the host's own hard limit for that user
  (`ulimit -l`) — asking for `-1` (unlimited) fails with `error setting rlimits for ready
  process: ... operation not permitted`, confirmed hitting this locally. Raising it requires
  host-level config (`/etc/security/limits.conf` or a systemd user unit's `LimitMEMLOCK=`),
  not anything settable from `docker-compose.yml`.

## Implementation notes: TPM-gated auto-unseal (PKCS#11)

Default OpenBao ships with Shamir seal: every container start (reboot, crash, or even a
`docker compose up -d` that recreates the container for an unrelated config change) comes back
`sealed: true`, and nothing un-seals it without a human running
`bao operator unseal` with key shares. This host also has a boot-time constraint (below) that
means an unattended reboot leaves the whole stack down until someone does that by hand.

**Chose TPM via PKCS#11 over the alternatives, after actually comparing them:**
- Cloud KMS (AWS/GCP/Azure/OCI/etc.) — ruled out: adds a cloud dependency this deployment
  otherwise avoids entirely.
- Transit seal / KMIP (a second OpenBao/Vault or KMIP server holds the key) — doesn't remove
  the bootstrap problem, only relocates it: that second system still needs to be trusted/unsealed
  by *something*, at some point.
- Static key seal — explicitly documented as only appropriate "when an existing source of
  trust... already exists"; we don't have one, OpenBao *is* the secrets manager here, so this
  would just be a plaintext key in a file/env var for anything to read. The exact anti-pattern
  this whole plan exists to avoid.
- PKCS#11 (HSM or TPM) is the only option that actually closes the loop while staying
  self-hosted: a piece of hardware releases the key based on physical possession of *this*
  machine, no second system to bootstrap trust into. TPM is the free instance of this category
  (already virtualizable under Proxmox) vs. buying a real HSM (Nitrokey/Utimaco/YubiHSM).

**This is TPM-*gated*, not TPM-*backed*.** No native TPM2 auto-unseal exists in OpenBao
([openbao/openbao#1200](https://github.com/openbao/openbao/issues/1200), open, no ETA — maintainers
want it built into their `go-kms-wrapping` fork rather than adopt an external wrapper). The
only real unseal-key store is `seal "pkcs11"`. So the actual chain is:
- **SoftHSM2** holds the real AES-256 key OpenBao unseals with (`openbao-unseal-key`, in a
  token on the persistent `softhsm-tokens` volume). This is a *software* HSM — the TPM does
  not directly hold the seal key.
- The TPM only seals SoftHSM's *login PIN* (`/openbao/tpm/pin.pub` + `pin.priv`, safe to leave
  as plaintext files on disk — useless without this exact machine's TPM to unseal them).
- `entrypoint-tpm.sh` runs on every container start, before `bao server`: `tpm2_createprimary`
  → `tpm2_load` → `tpm2_unseal` reconstructs the PIN, exports it as `BAO_HSM_PIN` (never
  written to disk), then execs `bao server`. If the vTPM is missing, migrated, or this isn't
  the same machine, `tpm2_unseal` fails and startup aborts here — that's the actual
  hardware-binding guarantee.

**Blockers hit and resolved, in order (all verified against the live container, not assumed):**
1. **This VM (Proxmox VMID 101) had a `tpmstate0` device in its config but no `/dev/tpm0`
   inside the guest.** TPM devices aren't hot-pluggable in Proxmox/QEMU — a `qm set` adding one
   doesn't attach it to an already-running QEMU process. Required a full **stop+start at the
   hypervisor level** (not a guest-level reboot, which just resets the same QEMU instance).
   After that, `/dev/tpm0` and `/dev/tpmrm0` appeared immediately.
2. **`openbao/openbao:2.6.2`'s standard Docker Hub image has PKCS#11 compiled out** —
   confirmed live: `Error configuring seal "pkcs11": this build of OpenBao has PKCS#11
   disabled`. PKCS#11 requires the separate `openbao-hsm_*` release build, which is
   **glibc/cgo-linked** (confirmed via `ldd`: `/lib64/ld-linux-x86-64.so.2`, `libc.so.6` — won't
   run on the standard image's Alpine/musl base). Fetched the `-hsm` binary from the GitHub
   release, **verified its SHA-256 against the published `checksums.txt`** before using it, and
   rebuilt the image from `debian:bookworm-slim` instead of Alpine.
3. **Alpine's `tpm2-tools` package doesn't pull in `tpm2-tss-tcti-device`** — without it,
   `tctildr` can't dlopen a backend for `device:/dev/tpm*` at all (fails with "Failed to
   instantiate TCTI" even though the raw device opens fine and permissions are correct). Moot
   after switching to Debian, whose `tpm2-tools` package pulls `libtss2-tcti-device0` in
   automatically — but cost an aborted SoftHSM token (see next point) before the switch.
4. **Device access via supplementary groups, not root/capabilities.** `/dev/tpm0` is group
   `root` (gid 0), `/dev/tpmrm0` is group `tss` (gid 105 on this host — confirm with
   `getent group tss` elsewhere). `group_add: ["0", "105"]` on the (still non-root,
   `cap_drop: ALL`) container grants both via normal DAC group-permission checks — no
   capabilities or root needed at any point.
5. **Named-volume ownership follows whatever owns that path in the image at first mount.**
   Hit this twice: once for `softhsm-tokens` (seeded root:root since nothing pre-created
   `/var/lib/softhsm/tokens` in the image — fixed by `mkdir`+`chown` to the `openbao` user in
   the Dockerfile before that path becomes a volume mount point), and once for
   `openbao-data`/`openbao-logs` (seeded under Alpine's `openbao` uid 100, then unreadable by
   Debian image's `openbao` uid 1000 after the base-image switch — `permission denied` on
   `vault.db`). Both times the fix was deleting the volume and letting Docker reseed it from
   the corrected image, safe here only because nothing had been initialized into Raft yet.
6. **SoftHSM token version drift across the Alpine→Debian switch.** Alpine shipped SoftHSM
   2.7.0, Debian bookworm ships 2.6.1. Rather than risk an undocumented forward-compatibility
   gap in the on-disk token format, wiped and fully re-ran provisioning (fresh PIN, fresh
   token, fresh AES key, fresh TPM seal) once on the final Debian image, instead of trying to
   carry the Alpine-provisioned token over.

**Provisioning (one-time, already done for this deployment):** SoftHSM token init +
`pkcs11-tool --keygen --key-type aes:32` for the AES-256 seal key, then
`tpm2_createprimary`/`tpm2_create -i -` sealing a freshly-generated random PIN to the TPM. The
PIN was generated and consumed entirely within one script's shell variables — no print/log/file
ever held it in plaintext, and the round-trip (`tpm2_load` + `tpm2_unseal` reproducing the
exact same PIN) was verified before trusting it. The SO-PIN used only for that one-time
provisioning was discarded on purpose — not needed again unless the token is re-provisioned
from scratch.

**Still a human step, unavoidably:** the very first `bao operator init` on this newly-emptied
Raft storage must still be run by a human with API/exec access (produces recovery keys +
initial root token, and this is the one place those values exist — they should never pass
through an assistant's context, same reasoning as the original root token). After that one-time
init, PKCS#11/TPM auto-unseal handles every subsequent restart with zero human involvement,
*except* two hard dependencies that don't have a purely-software fix:
- Host reboot must be registered in `~/Programs/start_docker_containers`'s `SERVICES` array
  (this host restores `unless-stopped`/`always` containers immediately on dockerd start, before
  its staggered-boot script — `~/Programs/staggered-startup.sh` — gets a chance to pace things;
  that staggering exists because of a prior VM-freezing incident. `openbao` and `comet-bao`
  are both now `restart: on-failure:5` and registered in that array).
- The vTPM itself must survive a hypervisor-level stop/start of VMID 101 intact and
  un-migrated — that's the actual security property being relied on, not a config detail to
  route around.

## Bottom line

Steps 2–4 (vault-backed injection + short-lived credentials + keeping resolution out of the
agent's context) are the only measures that structurally remove the assistant from the trust
boundary. Steps 1, 6, and 7 reduce accidental exposure but don't hold up against anything
adversarial or against the assistant's own shell access — plan accordingly for what actually
gets deployed here. The TPM auto-unseal work above extends the same principle one layer down:
the seal key material is provisioned once by automation and then never seen again by anything,
human or assistant — only released by a machine that can prove it *is* this exact host.
