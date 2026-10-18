# Additional contract tests

These tests extend the accepted suites without changing contracts or configuration.
They use the vendored forge-std and OpenZeppelin sources and need no network, fork,
environment mutation, external service, or additional dependency.

| Suite | Additional checks |
| --- | --- |
| `LaunchToken.edges.t.sol` | Zero and full-supply transfers, invalid recipients/spenders, maximum-value rejection, allowance replacement/revocation, finite and unlimited approvals, caller-specific spending, self-transfers, and transfer round trips. |
| `MnemoVault.adversarial.t.sol` | Late batch failures, one-wei-short balance/allowance, rollback of note ids and finite approvals, exact binary event payloads, stamp changes after approval, duplicate and mixed-owner forgets, agent payment isolation, revoke/regrant cycles, re-sealing an already-granted agent (current epoch in `Granted`, no rotation, no token movement, rejected re-seals keep the grant, per-vault isolation, one revoke still ends access), ownership replacement/cancellation, and token first-use failure. |
| `MnemoVault.stateful.t.sol` | Four actors drive 15 operations in random order. Independent model state checks token balances and allowances, stamp payments, every issued/forgotten note id, grants, keys, epochs, stamp changes, and two-step ownership. Re-granting a granted agent is modelled as a successful re-seal that keeps the grant and the epoch. A deterministic replay exercises successful writes, rejected writes, forgetting, regranting, re-sealing, and ownership handoff. |

New stateless fuzz properties use 1,000 runs each. The new invariant suite uses
256 sequences of up to 64 handler calls. Both settings are inline in the test
source. Expected failures are checked with exact revert data; unexpected handler
reverts fail the campaign. Inputs are bounded instead of discarded with assumptions.

The accounting model starts from the actual fixture allocations and updates from
requested operations. It does not copy observed contract state into its expectations.
It also sends tokens directly to the burn address and the vault: the burn address's
balance includes both stamp payments and donations, whereas `burnedTotal()` counts
only stamp payments. The complete set of reachable balances must sum to `10^27`,
including the tokens sent to the burn address. Forgetting never refunds a stamp,
decreases historical totals, or makes a note id reusable.

Run the ordinary project checks with the verifier's seed:

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0x43cf3374e61528ca3aa51841589a09a66ad3def0ba6e553a3b0e457412826fdf forge test --offline
```

All actors are local test fixtures. These tests verify the contracts' on-chain
behavior; browser encryption, provider privacy, deployment policy, and service
attestations are outside their scope.
