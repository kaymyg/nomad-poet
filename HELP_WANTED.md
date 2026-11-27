# Help wanted

The Nomad Poet is open to contributions. Below is the hardening work that would make it stronger, roughly in order of impact. Pick anything, comment on (or open) an issue so others know you are on it, and see [CONTRIBUTING.md](CONTRIBUTING.md) to get started.

Found a vulnerability instead? Please report it privately, see [SECURITY.md](SECURITY.md).


### Review clone and migrate logic

**High impact.** Each generation is an EIP-1167 clone with its own treasury. Review `migrate()` for reentrancy, griefing and treasury accounting issues.

### Static analysis and invariants

**Medium.** Add Slither to CI and Foundry invariant tests for lineage and treasury balances.

### Keeper key handling guide

**Good first issue.** `STEPS.md` already warns against private keys in shell history. Turn it into a short checklist for running the keeper safely.
