# V2 Commit Migration

The current sandbox mounts `.git` read-only, so the V2 commit was created in a
temporary Git mirror and exported as `demeter-v2-commit.bundle`.

Commit:

```text
0c60d4631f4464040bc5cba464db33c5d7bbbb16
```

After the repository `.git` directory is writable, import and fast-forward the
branch with:

```bash
git fetch ./demeter-v2-commit.bundle \
  0c60d4631f4464040bc5cba464db33c5d7bbbb16:refs/heads/redesign_v2_singleton
git switch redesign_v2_singleton
```

The bundle was verified with `git bundle verify` and contains a complete
history rooted at the previous branch tip. Re-run all release gates after
importing it; the bundle is a migration aid, not a substitute for production
fork tests or an independent audit.
