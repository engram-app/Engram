# OIDC deploy cutover

> **STAGING-ONLY / LARGELY SUPERSEDED — historical record.**
> This cutover applied to the **FastRaid (now staging)** deploy path, and
> only to the daemon's `/deploy` (image-roll) endpoint. That endpoint is now
> a **legacy fallback**. The live staging deploy path is the daemon's
> **`/tf-apply`** endpoint driven by a Terraform-tfvars var-bump PR
> (`bump-infra-tfvars` in `verify.yml`) — the same GitOps "image tag in git →
> engram-infra reconciles" model as prod. **PROD does not use this daemon at
> all**: prod ships via a `release-v*` tag → engram-infra Terraform apply on
> AWS ECS (see `docs/context/deploy-prod.md`). The OIDC token model, JWKS
> validation, cert/firewall setup, and SSH-key decommission below are still
> accurate for the staging daemon; treat the `/deploy`-rolls-the-image flow as
> the fallback, not the primary path.

Replaced the SSH-as-root deploy with a pull-based daemon
(`engram-deployer`) running on FastRaid. Runner mints a per-job OIDC
token, daemon validates against GitHub's JWKS and pins
`repository`/`ref`/`workflow_ref`. Runner holds zero long-lived
credentials.

See [engram-deployer repo](https://github.com/engram-app/engram-deployer)
for the daemon implementation. See `package/INSTALL.md` in that repo for
plugin install details.

## Cutover sequence (one-time)

These run AFTER PR `feat/oidc-deploy-cutover` lands. Until they're done,
the deploy-fastraid job will fail (missing secret).

### 1. Install plugin on FastRaid

Unraid web UI → **Plugins** → **Install Plugin** → paste:

```
https://github.com/engram-app/engram-deployer/releases/download/v0.1.0/engram-deployer.plg
```

The install hook generates a self-signed ed25519 cert (10-year validity)
and prints its SHA-256 fingerprint. Capture it.

### 2. Capture the cert PEM

```bash
ssh root@10.0.20.214 'cat /boot/config/plugins/engram-deployer/cert.pem'
```

Paste the entire PEM into a new repo secret on `engram-app/Engram`:

- **Name:** `DEPLOYER_CERT_PEM`
- **Value:** the PEM (including `-----BEGIN CERTIFICATE-----` lines)

### 3. Configure the daemon

On FastRaid:

```bash
cd /boot/config/plugins/engram-deployer
cp engram-deployer.env.sample engram-deployer.env
nano engram-deployer.env
```

Verify each `DEPLOYER_*` value. The defaults match this workflow's
expectations except for `DEPLOYER_ALLOWED_IPS` — set to the runner VM's
IP (`10.20.99.10`).

Then start the daemon:

```bash
/etc/rc.d/rc.engram-deployer start
/etc/rc.d/rc.engram-deployer status
tail -f /var/log/engram-deployer.log
```

### 4. Open the firewall on SlowRaid

The runner VM is isolated behind an allowlist on SlowRaid
(`/boot/config/iptables.runner.sh`). Add port 8443:

```bash
ssh root@10.0.20.201
# Edit /boot/config/iptables.runner.sh — in the FORWARD section, add:
#   iptables -A FORWARD -s 10.20.99.10 -d 10.0.20.214 -p tcp --dport 8443 -j ACCEPT
bash /boot/config/iptables.runner.sh
```

### 5. Smoke-test from the runner VM

```bash
ssh gh-runner   # alias for SlowRaid:2222 → VM
curl --cacert <(ssh root@fastraid 'cat /boot/config/plugins/engram-deployer/cert.pem') \
     https://10.0.20.214:8443/healthz
# → ok
```

### 6. Merge the cutover PR

Once 1-5 are done, merge `feat/oidc-deploy-cutover`. The first push to
main will trigger the new deploy path.

### 7. Decommission the old SSH key

After the first new deploy succeeds, remove the now-unused key from
FastRaid:

```bash
ssh root@10.0.20.214
# Edit /root/.ssh/authorized_keys — remove the line tagged
# "runner@gh-runner-vm-deploy"
```

Confirm by re-running a deploy from CI and seeing it work via OIDC
only.

## Architecture summary

```
┌───────────────────────┐       1. build + push image to GHCR
│ CI runner VM          │ ────────────────────────────────────▶ ghcr.io
│ (isolated, allowlist)  │
│                       │       2. core.getIDToken('engram-deploy')
│                       │          → fresh JWT per job (~15 min TTL)
│                       │
│                       │       3. POST + stream NDJSON              ┌─────────────────────┐
│                       │ ◀────────────────────────────────────────▶ │ engram-deployer     │
│                       │       4. terminal {status: "ok"|"fail"}    │ on FastRaid         │
│                       │       5. exit-code reflects                │ (Unraid plugin)     │
└───────────────────────┘                                            └─────────────────────┘

Validates JWT against GitHub JWKS  ↑
Pins: aud, repository, ref,
      workflow_ref, iat
JTI replay set (30min TTL)
Source IP allowlist
```

## Rollback (emergency)

If the new path is broken and a hotfix needs to ship:

1. Revert this PR on main
2. The `runner@gh-runner-vm-deploy` SSH key is still in FastRaid
   authorized_keys (Step 7 above is post-verification) — old SCP+SSH
   path will resume immediately
3. Investigate + re-merge a fixed version

After Step 7 completes, rollback requires re-adding the key. Don't do
Step 7 until you're confident.
