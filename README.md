# Ryfinite Token (RFN)

A fixed-supply ERC-20 for Ethereum. The only production contract is
[`RyfiniteToken`](src/RyfiniteToken.sol), using the vendored OpenZeppelin Contracts
v5.0.2 ERC-20 implementation.

| Parameter | Value |
| --- | --- |
| Solidity contract | `RyfiniteToken` |
| Token name | `Ryfinite Token` |
| Symbol | `RFN` |
| Decimals | `18` |
| Supply in whole tokens | `1,000,000,000` |
| Supply in base units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None |
| Constructor value | `0` ETH |
| Initial recipient | Immediate deployer (`msg.sender`) |
| Intended launch chain | Ethereum, chain ID `1` |

## Behavior and assumptions

The constructor mints `INITIAL_SUPPLY` once and emits the standard
`Transfer(address(0), deployer, INITIAL_SUPPLY)` event. All tokens go to the
immediate creator. With factory deployment, the factory receives everything;
the transaction origin and the requester receive no allocation in the constructor.

Transfers move exactly the specified number of base units. There are no token
taxes, transfer fees, rebases, burns, transfer restrictions beyond standard ERC-20
validation, or callbacks to recipients. Zero-amount transfers and self-transfers
are supported. Transfers to the zero address and approvals to the zero spender
revert with OpenZeppelin's ERC-6093 errors. Insufficient balances or allowances
also revert, rolling back the entire operation.

`approve` replaces the caller's allowance for a spender. `transferFrom` consumes
finite allowances; an allowance of `type(uint256).max` is treated as unlimited
and is not reduced. OpenZeppelin v5 emits `Approval` on explicit approval, but
does not emit it when `transferFrom` spends an allowance. Integrations should
query `allowance` for its current value.

RFN has no owner, privileged roles, public mint/burn functions, pause, blacklist,
seizure, upgrade mechanism, permit signatures, external dependencies at runtime,
or post-deployment initialization. The supply stays constant. These are deliberate
assumptions for a plain fixed-supply token; there is no operator who can change
the rules or recover a holder's lost funds.

## Build and test

Use Foundry with Solidity **0.8.26** installed. `foundry.toml` pins the compiler,
Cancun EVM, optimizer (200 runs), and `bytecode_hash = "none"`. All Solidity
dependencies and licenses are ordinary files under `lib/`; see
[`DEPENDENCIES.md`](DEPENDENCIES.md) for versions and archive checksums. No network,
environment secrets, package installation, filesystem cheatcode permissions, or
FFI are needed by the contracts or tests. A fresh offline verifier must provide
the pinned compiler, as specified by the assignment.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xd3f85c648954d0780e938e84afff65c2f655d8ec90b97d718c611485de395eb1 forge test
forge fmt --check
```

The tests cover metadata, the sole mint event, factory/CREATE2 deployment,
exact distribution and claim transfers, both transfer directions for a pool
custodian, allowance lifecycle, events, zero/self/full-balance transfers,
infinite allowances, unauthorized spending, error data, atomic rollback, rejected
administrative calls, rejected native ETH transfers, and forbidden runtime opcodes.
Fuzz tests use 1,024 cases per test. Stateful invariant tests run 128 sequences
of depth 64 over transfers, approvals, and delegated transfers, checking supply
conservation, allowance consumption, and immutable metadata.

The factory and custodian in the local tests are fixtures. They do not implement
Uniswap or prove actual pool seeding and swaps. The supplied protected integration
checks depend on the launch system's factory/pool sources, resolved manifest,
and environment, and are run by that system separately. They are not included in
this project's local test suite.

## Deployment and launch responsibilities

Deploy the creation bytecode for `src/RyfiniteToken.sol:RyfiniteToken` with no
appended constructor arguments and no ETH. Solidity callers can use
`new RyfiniteToken()`; factories can use CREATE or CREATE2. The constructor makes
no external calls and needs no chain-specific addresses. Deploy it directly,
without a proxy. There are no application contracts to deploy for this assignment.

The launch system prepares the manifest, deploys through its factory, and handles
all allocations. For this launch, its specified allocation is 10% to the swarm
distributor, 80% to the pool, and 10% to the requester's designated recipient.
The launch system also sets the opening market cap of 10 ETH, derives the price,
and handles the pool's 1.25% fee and tick spacing of 60. These are launch/pool
parameters, not RFN token settings or transfer fees. No recipient, pool, router,
distributor, or launch addresses are embedded in the token, and this project
does not create a launch manifest.

The deployer is responsible for checking the artifact and constructor inputs,
confirming the mint recipient, completing distribution, and verifying the source
and compiler settings after deployment. No transactions are broadcast by this
project's tests.

## After launch

There are no settings to configure, keys to operate the token, maintenance calls,
or administrative handovers. Holders manage their own transfers and approvals.
Approve trusted spenders for the amount needed and revoke unused allowances.
When changing a nonzero allowance, setting it to zero first and confirming the
transaction before setting the replacement reduces the standard ERC-20 allowance
replacement race; it cannot undo spending before revocation.

Ordinary native ETH transfers revert. Assets accidentally sent to this contract,
including RFN, other ERC-20 tokens, or forcibly sent ETH, have no recovery method.
Recipients must be able to manage tokens they receive.

Security review focused on the provided checklist's applicable points: fixed
supply, caller/allowance authorization, input validation, atomic failures, events,
and absence of external calls or upgrade paths. Local Foundry checks are not an
independent security audit. Launch integration checks, independent adversarial
review, and explorer verification remain the launch process's responsibilities.
Slither and Mythril were not run.
