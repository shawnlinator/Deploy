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

## Bottom line

Steps 2–4 (vault-backed injection + short-lived credentials + keeping resolution out of the
agent's context) are the only measures that structurally remove the assistant from the trust
boundary. Steps 1, 6, and 7 reduce accidental exposure but don't hold up against anything
adversarial or against the assistant's own shell access — plan accordingly for what actually
gets deployed here.
