const MAX_OPEN_ORDERS = 100

// Code version reported by the `version` getter, packed for ordering comparisons:
// (major << 16) | (minor << 8) | patch. Keep in sync with the `version` metadata
// string in TradingExtension.tolk. A deployment whose `version` get-method fails
// entirely predates 1.2.0 and should be treated as outdated.
const EXTENSION_VERSION_MAJOR = 1
const EXTENSION_VERSION_MINOR = 2
const EXTENSION_VERSION_PATCH = 0
const EXTENSION_VERSION = (EXTENSION_VERSION_MAJOR << 16) | (EXTENSION_VERSION_MINOR << 8) |
EXTENSION_VERSION_PATCH

struct SessionKeyInfo {
    validUntil: uint32
    seqno: uint32
}

// Read-only view returned by the sessionKeyStatus getter. When found == false the
// key is not registered (never added or revoked); otherwise compare validUntil to
// the current time off-chain to tell active from expired.
struct SessionKeyStatus {
    found: bool
    validUntil: uint32
    seqno: uint32
}

struct OrderInfo {
    validUntil: uint32
    nonce: uint32 // instance id, stamped from orderNonce; binds a trigger fire to this exact order
    // raw C5 out-actions linked list; opaque here, validated by the wallet on execution
    actions: cell
}

struct ExtensionStorage {
    walletAddress: address
    ownerKey: uint256      // pubkey that authorizes management (the wallet's own key)
    ownerSeqno: uint32     // replay guard for owner-signed management externals
    triggerKey: uint256    // 0 = unset
    openOrderCount: uint16 // maps have no size(); explicit counter enforces MAX_OPEN_ORDERS
    orderNonce: uint32     // monotonic; stamped onto each stored order (defeats orderId reuse replay)
    sessionKeys: map<uint256, SessionKeyInfo>
    orders: map<uint64, OrderInfo>
}

fun ExtensionStorage.load(): ExtensionStorage {
    return ExtensionStorage.fromCell(contract.getData());
}

fun ExtensionStorage.save(self) {
    contract.setData(self.toCell());
}

// external (signed): wire layout is [payload][512-bit Ed25519 signature over payload hash].
// The auth prefix travels as a ref (Cell<...>) so the root cell stays under 1023 bits;
// the signature covers it anyway, since cell hashes include refs.

// Management is owner-signed: only the holder of ownerKey can drive these. Binds to
// this extension instance (extAddrHash) and to a monotonic ownerSeqno for replay safety.
struct OwnerAuth {
    extAddrHash: uint256
    ownerSeqno: uint32
    validUntil: uint32
}

struct (0x53455301) AddSessionKey {
    auth: Cell<OwnerAuth>
    pubkey: uint256
    validUntil: uint32
}

struct (0x53455302) RevokeSessionKey {
    auth: Cell<OwnerAuth>
    pubkey: uint256
}

struct (0x54524701) SetTriggerKey {
    auth: Cell<OwnerAuth>
    pubkey: uint256 // 0 clears the trigger key
}

struct (0x51a70d01) StoreOrder {
    auth: Cell<OwnerAuth>
    orderId: uint64
    validUntil: uint32
    actions: cell
}

struct (0x51a70d02) CancelOrder {
    auth: Cell<OwnerAuth>
    orderId: uint64
}

struct (0x554e494e) Uninstall {
    auth: Cell<OwnerAuth>
}

// internal: the only accepted internal message is a plain top-up of the extension balance
struct (0x746f7075) TopUp {}

// Session auth is the shared prefix of every session-key-signed message; it binds the
// message to one extension instance (extAddrHash) and to the key's replay counter.
struct SessionAuth {
    extAddrHash: uint256
    pubkey: uint256
    validUntil: uint32
    seqno: uint32
}

struct (0x54524144) SessionTrade {
    auth: Cell<SessionAuth>
    outActions: cell
}

struct (0x54524f53) SessionStoreOrder {
    auth: Cell<SessionAuth>
    orderId: uint64
    orderValidUntil: uint32
    actions: cell
}

struct (0x54524f43) SessionCancelOrder {
    auth: Cell<SessionAuth>
    orderId: uint64
}

struct (0x54524947) TriggerFire {
    extAddrHash: uint256
    orderId: uint64
    nonce: uint32 // must equal the stored order's nonce; blocks stale-signature replay on reused ids
    validUntil: uint32
}
