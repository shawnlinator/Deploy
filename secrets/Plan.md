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

## Bottom line

Steps 2–4 (vault-backed injection + short-lived credentials + keeping resolution out of the
agent's context) are the only measures that structurally remove the assistant from the trust
boundary. Steps 1, 6, and 7 reduce accidental exposure but don't hold up against anything
adversarial or against the assistant's own shell access — plan accordingly for what actually
gets deployed here.
