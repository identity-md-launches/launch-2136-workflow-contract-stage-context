# MNEMO contracts

"Your AI's memory, sealed on chain."

Two contracts, built with Foundry for Ethereum mainnet (chain id 1):

| Contract      | File                  | Purpose                                                                                   |
| ------------- | --------------------- | ----------------------------------------------------------------------------------------- |
| `LaunchToken` | `src/LaunchToken.sol` | Mnemo (MNEMO), the fixed-supply ERC-20 the launch deploys and pairs with IMD.             |
| `MnemoVault`  | `src/MnemoVault.sol`  | Stores sealed notes as events, burns a MNEMO stamp per note, tracks key epochs and agents. |

ABI exports live in `docs/abi/LaunchToken.json` and `docs/abi/MnemoVault.json`.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `bytecode_hash = "none"` and `cbor_metadata = false`, with the
optimizer on at 200 runs. `ffi` is off and there are no filesystem permissions. Dependencies are vendored as
ordinary files under `lib/` (forge-std v1.11.0 and OpenZeppelin Contracts v5.4.0, sources and licences only).
Tests read no environment variables and pass in any order.

## LaunchToken

- Name `Mnemo`, symbol `MNEMO`, 18 decimals.
- Supply 1,000,000,000 MNEMO (10^27 minor units), minted once to `msg.sender` (the launch factory) in the
  constructor. No constructor arguments.
- Plain OpenZeppelin ERC-20 transfers. No owner, mint, burn hook, pause, blocklist, fee, tax or upgrade path.

The brief asked for exactly this (fixed supply, plain transfers, no tax, no mint), so nothing it asked of the
token is left out. The factory splits the supply after deployment: 10% to the swarm, the pool's share, and the
rest to the requester. Nothing in this repository is allocated, reserved or sent any of it at launch. The pool
pairs MNEMO with IMD at the launch policy's fee of 1.25%, set by the factory; no fee logic exists in these
contracts.

## MnemoVault

### Constructor

```
constructor(address token_, address owner_)
```

| Argument | Launch value | Meaning                                                              |
| -------- | ------------ | -------------------------------------------------------------------- |
| `token_` | `$token`     | The MNEMO `LaunchToken`. Stored as an immutable; never called at deploy. |
| `owner_` | `$owner`     | The launch owner (`0xc91633279dd9fa90d69f3c1b48c18a96fbd8ab67`). Only `setStamp`. |

Both must be non-zero. The constructor makes no external call and needs no other contract to exist, so it
runs on the empty chain the launch checks use. `MnemoVault` must be listed after the token in the manifest
because it references `$token`. The owner is the explicit argument, never `msg.sender` (the factory) or
`tx.origin`.

### Constants the contract enforces

| Constant             | Value                                        | Source                              |
| -------------------- | -------------------------------------------- | ----------------------------------- |
| `INITIAL_STAMP`      | 2,000 MNEMO per note                         | brief                               |
| `MIN_STAMP`          | 100 MNEMO per note                           | brief                               |
| `MAX_STAMP`          | 100,000 MNEMO per note                       | brief                               |
| `MAX_NOTE_BYTES`     | 2,048 bytes per note                         | brief                               |
| `MAX_NOTES_PER_CALL` | 16 notes per `write` / `writeFor`            | brief                               |
| `BURN_ADDRESS`       | `0x000000000000000000000000000000000000dEaD` | brief                               |

Choices the brief left open, made here and documented:

- An empty note (zero bytes) is rejected with `EmptyNote`. A ciphertext is never empty, and an empty event
  would be a free way to bump counters.
- A `sealedKey` passed to `grant` must be non-empty; there is no upper bound, since the caller pays the gas.
- `grant` requires the agent to have called `register` first, so the owner has a key to seal the vault key
  to, and rejects granting yourself or an already-granted agent.
- `forget` is all-or-nothing and a forgotten id cannot be forgotten twice (`NotNoteOwner`).
- `register` may be called again to replace a key. A zero key is rejected.

### Who can call what

| Caller            | Function                                              | Effect                                                                                       |
| ----------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Anyone with MNEMO | `write(bytes[] notes, uint32 epoch)`                  | Seals 1–16 notes into the caller's vault; burns `stamp × notes` from the caller.             |
| Note owner        | `forget(uint256[] ids)`                               | Marks the caller's live notes forgotten; emits `Forgotten` per id.                           |
| Vault owner       | `rotate()`                                            | Epoch + 1; emits `Rotated`.                                                                  |
| Vault owner       | `grant(address agent, bytes sealedKey)`               | Agent may `writeFor` this vault; emits `Granted(owner, agent, epoch, sealedKey)`.            |
| Vault owner       | `revoke(address agent)`                               | Removes the grant and rotates the epoch; emits `Revoked` then `Rotated`.                     |
| Granted agent     | `writeFor(address owner, bytes[] notes, uint32 epoch)` | Seals notes into `owner`'s vault; burns the stamp from the agent's own MNEMO.               |
| Anyone            | `register(bytes32 x25519PublicKey)`                   | Publishes a key so vault owners can grant this address; emits `KeyRegistered`.               |
| Launch owner      | `setStamp(uint256)`                                   | New stamp within [100, 100,000] MNEMO, future writes only; emits `StampChanged(old, new)`.   |
| Launch owner      | `transferOwnership` / `acceptOwnership`               | OpenZeppelin `Ownable2Step`: the new owner must accept.                                      |

`renounceOwnership` always reverts (`RenounceDisabled`). There is no pause, no upgrade, no withdrawal and no
other owner power. The vault never holds tokens: every stamp goes straight from the payer to `BURN_ADDRESS`
in the same call via `transferFrom`, so each writer must `approve` the vault first.

Views: `epochOf(owner)`, `isGranted(owner, agent)`, `notesTotal()`, `burnedTotal()`, `keyOf(account)`,
`noteOwnerOf(id)`, `stamp()`, `token()`, `owner()`, `pendingOwner()`.

Events: `Noted(owner, id, epoch, ciphertext)`, `Forgotten(owner, id)`, `Rotated(owner, epoch)`,
`Granted(owner, agent, epoch, sealedKey)`, `Revoked(owner, agent)`, `KeyRegistered(account, key)`,
`StampChanged(old, new)`. Note ids count up from 1 across the whole contract, and `notesTotal()` equals the
last id issued.

### Epoch rules

A vault's epoch starts at 0. `write` and `writeFor` must pass the vault owner's current epoch, so a client
holding a stale key cannot seal a note under the wrong key. `rotate` and `revoke` each add one. Rotation does
not touch earlier ciphertext, which stays on chain; it only makes later notes unreadable to anyone holding
only an older sealed key. The site derives the vault key as HKDF of a wallet signature and the epoch; the
contract never sees keys or plaintext.

## Assumptions and trust

- **Ciphertext only.** The contract stores whatever bytes it receives in events. It cannot check that they are
  encrypted, well-formed or meaningful. Confidentiality rests entirely on the browser-side encryption described
  in the brief, and on the wallet being an EOA whose `personal_sign` is deterministic.
- **Burn is final.** Tokens sent to `0x…dEaD` are unrecoverable. `burnedTotal()` equals the MNEMO this
  contract has sent there (tested as an invariant), but the dead address may also receive MNEMO from elsewhere.
- **Stamp is the owner's one lever.** The launch owner can move the per-note price between 100 and 100,000
  MNEMO at any time, for future writes only. A user who approved a large allowance and signs a `write` after a
  stamp increase pays the new price; the site should show the current `stamp()` before every transaction.
  This power is required by the brief and is a trust assumption on the owner.
- **Agents pay their own stamp.** `writeFor` never touches the vault owner's balance. An agent can only add
  notes, never forget them, and only while granted and only under the owner's current epoch.
- **Grants are per owner.** A grant from Alice does not let the agent write to Bob's vault.
- **No reentrancy surface.** The only external call is the token `transferFrom` at the end of `_write`, after
  all state is final, and MNEMO is a plain ERC-20 with no hooks. A different token with callbacks would still
  find the state settled.
- **Forbidden opcodes.** No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; no proxy; runtime about 4.4 KB.
- **Epoch overflow.** The epoch is a `uint32` with checked arithmetic. Rotating 2^32 times would revert;
  this is not reachable in practice.

## Operational responsibilities

- **After launch, nothing must be set.** The vault has no outside-service values. The owner may optionally
  adjust the stamp with `setStamp(uint256)` (minor units, 18 decimals; 2,000 MNEMO is `2000e18`). Any value
  outside [100e18, 100_000e18] reverts.
- **Owner key hygiene.** `$owner` is the only address that can change the stamp or hand over ownership.
  Ownership transfer is two-step; renouncing is impossible, so the owner key should be kept recoverable.
- **Site integration.** Clients must `approve(vault, stamp × n)` before `write`/`writeFor`, pass
  `epochOf(owner)` as the epoch, and read notes by indexing `Noted` events (dropping ids that appear in
  `Forgotten`). Network totals come from `notesTotal()` and `burnedTotal()`.
- **Not deployed here.** IMD's deployer launches both contracts through the factory after review. This
  repository contains no deploy scripts, keys or broadcast artefacts, and no `launch.json` (the manifest
  step writes it). Explorer verification belongs to the deployer.

## Tests

`forge test` runs 64 tests across three suites:

- `test/LaunchToken.t.sol`: metadata, whole supply to the deployer, exact transfers, allowance, no mint, a
  conservation fuzz.
- `test/MnemoVault.t.sol`: constructor (owner argument, zero checks, no call to the token), `write` success
  and every failure path (no notes, too many, too long, empty note, wrong epoch, no balance, no allowance,
  partial balance), stamp changes applying to future writes only, `forget` (own, foreign, unknown, double,
  all-or-nothing, agent cannot forget), `rotate`, `register`, `grant`/`revoke` (unregistered, zero, self,
  duplicate, revoke rotates, re-grant), `writeFor` (pays from agent, attribution, revoked, stale epoch, per
  owner, limits, broke agent), owner powers (range, access, two-step transfer, renounce disabled), and fuzz
  tests for stamp × count burning, stamp range, epochs and forget authorisation.
- `test/MnemoVault.invariant.t.sol`: a handler drives four actors through every function; invariants hold
  that `burnedTotal()` equals the dead address balance and the handler's ghost total, the vault holds nothing,
  `notesTotal()` matches the ghost count, epochs match, supply is conserved and the owner never changes.

Tests passing are not a security audit. The vault burns user funds on their instruction and holds none, but an
independent adversarial review is still part of this stage before launch. Slither and Mythril were not run
(not available on this worker); forge's built-in lints produced only style warnings.
