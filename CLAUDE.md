# TradingExtension — Wallet V5 trading extension for TON

A Wallet V5 (v5r1 only) extension written in **Tolk**, built with the **Acton** toolchain.
Features: session keys (delegated trading), stored limit orders, and a trigger key that can
fire stored orders.

## Layout

- `contracts/` — contract sources: `TradingExtension.tolk` (entrypoints + getters),
  `types.tolk` (storage/messages/consts), `errors.tolk`, `w5-types.tolk`, `walletv5/` (Wallet V5).
- `wrappers/*.gen.tolk` — **GENERATED** by `acton wrapper <ContractName>`; never hand-edit,
  regenerate after changing a contract's getters/messages.
- `scripts/` — standalone Tolk scripts (deploy, install/delete extension, add-session-key,
  set-trigger-key, store/cancel/trigger order, session-trade, session-status, swap). Inputs come
  from env vars (e.g. `EXT_ADDRESS`, `SESSION_SEED`, `W5_DEPLOYER`).
- `tests/trading-extension.test.tolk` — native Tolk tests (`get fun \`test ...\`()` style).
- `build/` — compiled BoC + code hash, `build/abi/` — ABI JSON (metadata, get-methods).

## Commands

- `acton build` — compile all contracts, refresh `build/` + ABI.
- `acton wrapper TradingExtension` — regenerate the wrapper after contract changes.
- `acton test` — run the test suite.
- `acton script scripts/<x>.tolk --net testnet|mainnet` — run an action; named shortcuts live in
  `Acton.toml [scripts]` (run via `acton run <name>`).

## Invariants to preserve

- **Owner-auth**: all management (add/revoke session key, set trigger key, store/cancel order,
  uninstall) is owner-key-signed **external** messages only. Never authorize by
  `sender == wallet` — the wallet forwards messages on other parties' behalf, so that would let
  a session key escalate to management. The only accepted internal message is `TopUp`.
- **Forwarding safety**: session/trigger actions forward out-actions to the wallet with
  `hasExtraActions: false` (can never touch extensions or signature mode) and reject
  `FORBIDDEN_SEND_MODES` (no carry-all-balance sweep, no destroy).
- **Replay guards**: `ownerSeqno` (management), per-session-key `seqno` (trades), and order
  `nonce` (trigger fires). State is saved + committed **before** any send — order firing is
  one-shot (rebroadcast hits OrderNotFound/WrongOrderNonce; a bounced fired order stays deleted).
- **Fee model**: `REQUEST_VALUE` (0.02 TON) attached to forwarded requests only funds the
  wallet's compute phase; actual transfers are paid from the wallet balance
  (pay-fees-separately), unspent remainder stays in the wallet.

## Versioning

- The contract exposes `get fun version(): int`, packed as `(major << 16) | (minor << 8) | patch`
  (e.g. 1.2.0 → `0x010200`). Bump the metadata `version: "x.y.z"` string in
  `TradingExtension.tolk` **and** the `EXTENSION_VERSION_*` consts in `contracts/types.tolk`
  together.
- New code ⇒ new extension address ⇒ upgrade path is uninstall → deploy → install (session keys
  must be re-added). Clients detect an outdated install by comparing the getter result to the
  current build's `EXTENSION_VERSION`; a **failed** `version` get-method call means a pre-1.2.0
  deployment — also outdated.
- `README.md` is the integrator/trading-terminal-facing doc (architecture, security model, fees,
  script reference, session-key monitoring, version check + upgrade walkthrough). When contract
  behavior, getters, or the upgrade flow change, update the matching README section too.
