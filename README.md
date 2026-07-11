# TradingExtension — a Wallet V5 trading extension

A TON smart contract project (Tolk, Acton toolchain) implementing a **trading
extension** for a standard Wallet V5 (v5r1) wallet. The user's funds stay in
their normal W5 wallet — visible in Tonkeeper / MyTonWallet — while a separate
extension contract, installed through W5's extension mechanism, holds the
trading logic:

- **Session keys** — temporary Ed25519 keys the owner can add and revoke. A
  valid, unexpired session key can make the wallet send transfers and can store
  or cancel limit orders, but can never manage keys or extensions.
- **Stored limit orders** — pre-approved outgoing transfers with an expiry,
  capped at **100 open orders**, stored by the owner or by a session key.
- **Trigger key** — a single webservice key that can *only* fire stored,
  unexpired orders by id. Nothing else.

When an order fires or a session key trades, the extension sends an
authenticated `0x6578746e` ("extn") internal message to the W5 wallet, and the
wallet executes the transfer from its own balance.

## Architecture

```
owner (wallet mnemonic)
  │  signed W5 external ── out-action ──► TradingExtension   (management ops:
  │                                        add/revoke session key, set trigger
  ▼                                        key, store/cancel order, uninstall)
Wallet V5 ◄── W5ExtensionActionRequest ── TradingExtension
  │            (out-actions only,           ▲            ▲
  ▼             hasExtraActions=false)      │            │
transfer to recipient           session-key-signed   trigger-key-signed
(paid from wallet balance)      external (trade,     external (fire stored
                                store/cancel order)  order, one-shot)
```

**One extension instance per wallet.** The extension's address derives from its
initial storage, which embeds the owning wallet's address — so every wallet
deploys its own instance holding only its own session keys, orders, and trigger
key. There is no shared global contract. The wallet whitelists exactly that one
address in its extensions dictionary.

### Security model

Three distinct authorities, each proven cryptographically — never by "which
address sent the message":

- **Owner management** is **owner-signed**. The extension stores the wallet's
  own public key (`ownerKey`); add/revoke session key, set trigger key,
  store/cancel order, and uninstall are externally-signed messages verified
  against `ownerKey` with a monotonic `ownerSeqno`. One signature, no
  confirmation, no wallet round-trip. Because authority is the *signature* (not
  "came from the wallet"), a session key cannot loop a message through the
  wallet to reach a management handler.
- **Session trades / order ops** are session-key-signed: the extension strips a
  trailing 512-bit Ed25519 signature and verifies it against the session
  pubkey. Replay protection: per-key `seqno` (bumped and committed *before* the
  send; **preserved** — never reset — when a key is re-added to refresh its
  expiry), binding to this extension instance (`extAddrHash`), and a message
  `validUntil`.
- **Trigger fires** are trigger-key-signed and carry the target order's
  `nonce`. Each stored order gets a unique, monotonic nonce, so a captured
  trigger signature can't fire a *different* order that later reuses the same
  id. The order is also deleted and committed before the forward, so a plain
  rebroadcast hits `OrderNotFound`.
- **Forwarded actions are constrained.** The session/trigger path forwards
  out-actions with `hasExtraActions: false` hard-coded (no add/remove extension
  or signature-mode change), and the extension rejects any action using send
  mode `128` (carry-all-balance) or `32` (destroy) — so a leaked session key
  can transfer funds but can't atomically empty-and-brick the wallet.
- Session keys may transfer any amount to any destination (needed for DEX
  swaps and jetton transfers) until revoked or expired — revocation/expiry is
  the safety valve. Revoking a key does **not** cancel orders it already stored;
  review open orders via the `extensionInfo` getter and cancel any you don't
  want.
- **Residual, inherent to Wallet V5:** any *other* extension you install into
  the same wallet is separately trusted by the wallet and can command it. Only
  install extensions you trust alongside this one.

### Fees — who pays what

The **trades themselves are paid by the W5 wallet**, from its own balance: the
forwarded out-actions use pay-fees-separately, so the recipient amount and its
fees come out of the wallet. The extension does **not** fund transfers.

The extension does need a small standing balance, though, and it can't be zero.
A session trade / trigger fire arrives as an **external** message (no value),
and TON charges the *receiving* contract — the extension — for the compute gas
to process it. The extension then forwards the request to the wallet with a
small `REQUEST_VALUE` (~0.02 TON): on TON an internal message's compute gas is
funded by the message value, so this cannot be 0 or the wallet would skip its
compute phase and never execute the trade. It only needs to cover the wallet's
compute; any unspent remainder just stays in the wallet. So the extension's real
per-trade cost is that small forward value plus its own external-processing gas —
top the extension up occasionally with a `TopUp` message.

To close even that last sliver, the bot can append one extra out-action per
trade — a small wallet→extension top-up — so the wallet refills the extension's
gas each trade. Net effect: in steady state everything is paid from the W5
wallet, and the extension just holds a small buffer that stays roughly constant
(it needs a one-time float to cover the very first trade before its refill
arrives).

## Layout

- `contracts/TradingExtension.tolk` — the extension contract.
- `contracts/types.tolk`, `contracts/errors.tolk`, `contracts/w5-types.tolk` —
  storage, messages, errors, and W5 action types.
- `contracts/walletv5/` — vendored Wallet V5 contract for end-to-end testing.
- `wrappers/TradingExtension.gen.tolk`, `wrappers/WalletV5.gen.tolk` —
  generated wrappers (regenerate with `acton wrapper TradingExtension`).
- `wrappers/utils.tolk` — hand-written helpers: signed session/trigger bodies,
  out-action packing, W5 signed requests, deploy helpers.
- `tests/trading-extension.test.tolk` — end-to-end tests against an emulated
  real W5 wallet: install → trade/store/fire → the wallet actually sends, plus
  replay, expiry, cap, and authorization negative cases.
- `scripts/` — deploy, install/delete, key management, order, trigger, and
  read-only `session-status` scripts (see below).

## Build & test

```bash
acton build   # compile + regenerate wrappers
acton test    # full emulated end-to-end suite
```

Try the deploy in emulation (no network):

```bash
acton run deploy-emulation
```

## Scripts

Wallets come from the acton wallet registry (`W5_DEPLOYER` env or interactive
prompt). Session/trigger keys are independent Ed25519 keys derived from
`SESSION_SEED` / `TRIGGER_SEED` (uint256, hex or decimal); without a seed the
scripts generate a keypair and print the seed to persist. All settings are
documented in `.env.example`. If you need higher Toncenter limits, copy
`.env.example` to `.env` and set `TONCENTER_TESTNET_API_KEY` /
`TONCENTER_MAINNET_API_KEY`.

| Alias (`acton run …`) | What it does | Auth |
|---|---|---|
| `deploy-testnet` | deploy the extension for `W5_DEPLOYER` | owner |
| `install-extension` | add the extension to the wallet | owner |
| `delete-extension` | remove the extension from the wallet | owner |
| `add-session-key` | register a session key (`SESSION_VALID_SECS`) | owner |
| `set-trigger-key` | set (or clear with `TRIGGER_PUBKEY=0`) the trigger key | owner |
| `store-order` | store a limit order (`ORDER_ID`, `ORDER_TARGET`, `ORDER_AMOUNT`, `ORDER_TTL_SECS`) | session key |
| `cancel-order` | cancel a stored order | session key |
| `session-trade` | immediate transfer (`TRADE_TARGET`, `TRADE_AMOUNT`) | session key |
| `trigger-order` | fire a stored order by `ORDER_ID` | trigger key |
| `session-status` | report a session key's lifecycle (read-only) | none (public key) |
| `swap` | execute one pre-built DEX transaction (`SWAP_DEST`, `SWAP_AMOUNT`, `SWAP_PAYLOAD`) | session key |

Amounts (`ORDER_AMOUNT`, `TRADE_AMOUNT`) are in nanotons.

### Keys never leave your machine

Only **public** keys and **signatures** ever go on-chain — a private key (seed)
is never transmitted or stored in the contract. `add-session-key` publishes the
session key's *public* key; trades and fires carry an Ed25519 *signature* the
contract verifies against that public key. The `SESSION_SEED` / `TRIGGER_SEED`
values are the private seeds: the scripts derive the keypair locally and keep
the seed on your machine. Keep them secret — a seed authorizes trading — but
know that broadcasting a transaction never reveals it.

### Monitoring session keys (remind the owner to refresh)

TON has no on-chain timers or expiry events, so a trading terminal **polls** to
know when a session key is about to lapse. Two read-only surfaces:

- Getter `sessionKeyStatus(pubkey) -> { found, validUntil, seqno }` — one cheap
  call per key (cheaper than `extensionInfo()`, which returns the whole storage
  including up to 100 orders). `found == false` means not registered (never
  added, or revoked). If found, compare `validUntil` to the current time to tell
  active from expired.
- Script `acton run session-status` (env `EXT_ADDRESS` + `SESSION_PUBKEY`,
  optional `REFRESH_WINDOW_SECS`) — prints `NOT REGISTERED` / `EXPIRED` /
  `EXPIRING SOON` / `ACTIVE` with seconds remaining.

Monitoring needs only the **public** key — pass `SESSION_PUBKEY`, never the
seed. Terminal logic:

```
s = sessionKeyStatus(pubkey)
if not s.found:                          -> revoked/absent: ask owner to re-register
elif s.validUntil <= now:                -> expired: ask owner to refresh
elif s.validUntil - now < REFRESH_WINDOW -> expiring soon: prompt refresh
else:                                    -> active
```

Refreshing is just `add-session-key` again with the same public key: it extends
`validUntil` and **preserves the seqno**, so in-flight trades aren't disrupted.
Use a comfortable refresh window (minutes-to-hours, not seconds): `validUntil`
is compared on-chain against block time, which can lag wall-clock slightly.

### Checking the extension version (detect outdated installs)

Since v1.2.0 the contract exposes a `version()` getter, so a trading terminal
can detect an outdated installed extension and walk the owner through an
upgrade.

- `version() -> int`, packed as `(major << 16) | (minor << 8) | patch` — e.g.
  1.2.0 → `0x010200` (66048). Decode: `major = v >> 16`,
  `minor = (v >> 8) & 0xFF`, `patch = v & 0xFF`. Packing preserves ordering, so
  a plain integer `<` comparison answers "is it older?".
- The expected value for the code you built is `EXTENSION_VERSION` in
  `contracts/types.tolk`; the human-readable string is the `version` metadata in
  `contracts/TradingExtension.tolk` and in `build/abi/TradingExtension.json`.
  Bump both together on every release.
- **A failed `version()` call means a pre-1.2.0 deployment** — the get-method
  doesn't exist there. Treat it as outdated too.

Terminal logic:

```
v = version(extAddress)              # runGetMethod on the extension
if the call fails:                   -> pre-1.2.0: outdated
elif v < EXPECTED_VERSION:           -> outdated: prompt the owner to upgrade
else:                                -> up to date
```

Contract code is immutable on TON, and the extension address derives from its
code + initial storage — so an upgrade is never in-place; it's an
**uninstall → reinstall** of a new instance at a **new address**:

1. `delete-extension` — owner-signed; removes the extension from the wallet and
   sweeps the old instance's remaining balance back to the wallet.
2. Deploy the new build (`deploy-testnet`, or `deploy.tolk --net mainnet`) —
   this prints a **new extension address**; replace the stored `EXT_ADDRESS`
   everywhere the terminal keeps it.
3. `install-extension` for the new address.
4. Re-add session keys (`add-session-key`) and re-set the trigger key
   (`set-trigger-key`). Stored orders do **not** carry over — re-store any that
   should stay open. Session-key seqnos start at 0 again on the new instance.

## Testnet walkthrough

1. Create (or reuse) a v5r1 wallet in the registry and fund it:

```bash
acton wallet new --name deployer_v5 --version v5r1 --global
acton wallet airdrop deployer_v5
```

2. Deploy and install:

```bash
W5_DEPLOYER=deployer_v5 acton run deploy-testnet          # prints the extension address
W5_DEPLOYER=deployer_v5 EXT_ADDRESS=<addr> acton run install-extension
```

3. Configure keys (pick your own secret seeds):

```bash
W5_DEPLOYER=deployer_v5 EXT_ADDRESS=<addr> SESSION_SEED=0x<hex> acton run add-session-key
W5_DEPLOYER=deployer_v5 EXT_ADDRESS=<addr> TRIGGER_SEED=0x<hex> acton run set-trigger-key
```

4. Trade and run the order flow — note that neither command needs the wallet
   mnemonic anymore:

```bash
EXT_ADDRESS=<addr> SESSION_SEED=0x<hex> TRADE_TARGET=<addr> acton run session-trade
EXT_ADDRESS=<addr> SESSION_SEED=0x<hex> ORDER_ID=1 ORDER_TARGET=<addr> acton run store-order
EXT_ADDRESS=<addr> TRIGGER_SEED=0x<hex> ORDER_ID=1 acton run trigger-order
```

5. Optionally uninstall:

```bash
W5_DEPLOYER=deployer_v5 EXT_ADDRESS=<addr> acton run delete-extension
```

Validate everything on testnet before touching mainnet. For mainnet, run the
same scripts with `--net mainnet`
(`acton script scripts/<name>.tolk --net mainnet`) — after a careful review and
ideally an external audit; this code has not been audited.

## Swapping TON → USD₮ (DeDust)

A swap is just a session trade whose out-action carries a DEX payload to a DEX
vault instead of a plain transfer — so no contract change is needed. The flow
uses DeDust's v4 router API to build the transaction, then routes it through a
session key:

1. `POST https://mainnet.api.dedust.io/v4/router/quote` with
   `{in_minter:"native", out_minter:"<USD₮ master>", amount, swap_mode:"exact_in", slippage_bps, max_splits:1}`
   → returns `out_amount` and a `swap_data` object.
2. `POST /v4/router/swap` with `{sender_address:"<your W5 wallet>", swap_data}`
   → returns `transactions: [{ address, amount, payload }]` (one for a single
   route). `address` is the DeDust Native Vault, `amount` is the TON to send
   (swap amount + gas), `payload` is the base64 BoC swap message.
3. Feed that transaction to `scripts/swap.tolk` (env `SWAP_DEST` / `SWAP_AMOUNT`
   / `SWAP_PAYLOAD`): the session key signs a trade whose out-action makes the
   **wallet** send `SWAP_AMOUNT` to the vault with the payload. The wallet pays
   from its balance and the USD₮ lands in the wallet.

Mainnet only — USD₮ is a mainnet jetton, and the amount is real. Request
`max_splits: 1` so the router returns a single transaction; a very large amount
that DeDust can only fill by splitting across pools is rejected (use less).

## CI

`.github/workflows/contracts.yml` runs `acton build`, `acton fmt --check`,
`acton check --output-format github`, and `acton test`.

## Documentation

- Quickstart: https://ton-blockchain.github.io/acton/docs/quickstart
- Testing: https://ton-blockchain.github.io/acton/docs/commands/test
- Scripts and deployment: https://ton-blockchain.github.io/acton/docs/commands/script
- Wrappers: https://ton-blockchain.github.io/acton/docs/commands/wrapper
- Wallets: https://ton-blockchain.github.io/acton/docs/commands/wallet
