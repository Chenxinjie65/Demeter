# Contributing

Demeter V2 development happens on `main`. Changes must preserve the singleton
custody, proportional claim, auction-only rebalancing, and uninterrupted
redemption invariants documented in `docs/ARCHITECTURE_V2.md`.

Before submitting a change:

1. Keep each commit behaviorally focused.
2. Add focused tests proportional to the change's risk.
3. Run `bash script/v2/check-format.sh` and `git diff --check`.
4. Run `forge test --match-path 'test/v2/**' --summary`.
5. For release-sensitive changes, also run the size, Slither, release invariant,
   and arithmetic fuzz gates listed in `docs/RELEASE_CHECKLIST_V2.md`.

Never commit private keys, RPC credentials, deployment secrets, broadcast logs,
or generated simulator output. Report security issues using `SECURITY.md`, not
through a public issue.
