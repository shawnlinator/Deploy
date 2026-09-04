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

- **Grant `mlock` instead of disabling it.** OpenBao (like Vault) calls `mlock()` to keep its
  own secret-holding memory pages from ever being swapped to disk. Docker doesn't grant the
  needed capability by default, so add it explicitly, along with raising the locked-memory
  ulimit (Docker's default is too low for mlock to succeed even with the capability):
  ```
  docker run --cap-add=IPC_LOCK --ulimit memlock=-1:-1 ...
  ```
  Leave `disable_mlock = false` (the default) when this is in place.

- **Known caveat with Integrated Storage (Raft).** A single-host self-hosted deployment
  will likely use Raft (no external Consul) as the storage backend. Raft's storage engine
  (bbolt) mmaps its entire database file, and mlock forces that whole mmap into physical RAM
  immediately — memory usage grows with the secrets DB, not with what's actively in use. Load-
  test with realistic data volume before relying on this in production.

- **Decision: deny the OpenBao container swap entirely via cgroups, rather than encrypting
  host swap.** Swap isn't namespaced per container — `swapon` registers a device/file for the
  whole host, shared by every container — so there's no way to give just OpenBao its own
  encrypted swap volume. Setting the cgroup swap limit equal to the memory limit removes the
  question instead of mitigating it: there's no swap for this container to use, encrypted or
  not.
  ```
  docker run --cap-add=IPC_LOCK --ulimit memlock=-1:-1 --memory=1g --memory-swap=1g ...
  ```
  - `--memory-swap` equal to `--memory` gives the container's cgroup zero swap headroom. If
    it exceeds the memory limit it gets OOM-killed rather than swapped — the right failure
    mode for a secrets-manager container, and it backstops `mlock` structurally even if
    `IPC_LOCK` couldn't be granted for some reason (`disable_mlock = true` fallback), since
    the cgroup limit blocks swap regardless of whether OpenBao itself ever calls `mlock()`.
  - Size `--memory` for worst-case, not steady-state: combined with the Raft/mmap caveat
    above, the whole secrets DB gets pulled into resident memory and there's no swap left as
    slack if it grows past the limit — it gets killed, not degraded. Size the limit against
    projected data volume with headroom, and monitor container memory usage as the vault's
    contents grow.
  - This makes host-level swap encryption unnecessary *for this container* — OpenBao simply
    never touches host swap. Encrypting host swap is still worth doing independently if other
    processes on the same host handle sensitive data, but it's no longer this plan's control
    for OpenBao specifically.

## Bottom line

Steps 2–4 (vault-backed injection + short-lived credentials + keeping resolution out of the
agent's context) are the only measures that structurally remove the assistant from the trust
boundary. Steps 1, 6, and 7 reduce accidental exposure but don't hold up against anything
adversarial or against the assistant's own shell access — plan accordingly for what actually
gets deployed here.
