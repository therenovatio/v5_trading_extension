import "@stdlib/gas-payments"
import "@contracts/errors"
import "@contracts/w5-types"
import "types"

contract TradingExtension {
    author: "itsdeadcow"
    version: "1.2.0"
    description: "Wallet V5 trading extension: session keys, stored limit orders, trigger key"
    storage: ExtensionStorage
    incomingMessages: AllowedInternalMessages
    incomingExternal: AllowedExternalMessages
}

// The only accepted internal message is a plain top-up; everything with authority
// (management + trading) is an externally-signed message, so a message the wallet
// forwards on some other party's behalf can never reach a privileged handler.
type AllowedInternalMessages = TopUp

type AllowedExternalMessages =
    | AddSessionKey
    | RevokeSessionKey
    | SetTriggerKey
    | StoreOrder
    | CancelOrder
    | Uninstall
    | SessionTrade
    | SessionStoreOrder
    | SessionCancelOrder
    | TriggerFire

const SIZE_SIGNATURE = 512

// Value attached to the request so the wallet can pay its own compute gas. On TON
// an internal message's compute gas is funded by the message value, so this cannot
// be 0 (the wallet would skip its compute phase and never process the request).
// It only needs to cover the wallet's compute — the actual transfers are paid from
// the wallet balance (the out-actions use pay-fees-separately) — and any unspent
// remainder simply stays in the wallet. Kept small to minimise the extension's
// per-trade outlay; the wallet, not the extension, funds the trades themselves.
const REQUEST_VALUE = ton("0.02")

// Send modes that would let a forwarded action empty and/or destroy the wallet in
// one shot. Session/trigger actions may transfer any amount to any destination, but
// never sweep the whole balance or self-destruct the wallet.
const FORBIDDEN_SEND_MODES = SEND_MODE_DESTROY | SEND_MODE_CARRY_ALL_BALANCE

// The single path from session/trigger authority to the wallet: out-actions only.
// hasExtraActions is hard-coded to false, so these keys can never add/remove
// extensions or change the wallet signature mode.
fun forwardOutActionsToWallet(walletAddress: address, outActions: cell, queryId: uint64) {
    val requestMsg = createMessage({
        body: W5ExtensionActionRequest {
            queryId,
            outActions,
            hasExtraActions: false,
            extraActions: createEmptySlice(),
        },
        bounce: false,
        dest: walletAddress,
        value: REQUEST_VALUE,
    });
    requestMsg.send(SEND_MODE_REGULAR);
}

// Walk the C5 out-actions linked list (same layout as buildOutActionsCell / the wallet's
// verifyC5Actions) and reject any action whose send mode could sweep or destroy the wallet.
// The wallet only executes send-message actions, but for extension-originated requests it
// does NOT restrict the send mode, so we do it here.
fun assertSafeOutActionModes(outActions: cell) {
    var cs = outActions.beginParse();
    while (!cs.isEmpty()) {
        val prev = cs.loadRef();
        cs.skipBits(32); // 0x0ec3c86d "send message" prefix
        val sendMode = cs.loadUint(8);
        cs.loadRef();    // the message cell
        assert ((sendMode & FORBIDDEN_SEND_MODES) == 0) throw Errors.UnsafeSendMode;
        cs = prev.beginParse();
    }
}

fun ExtensionStorage.validateOwnerAuth(
    self,
    auth: OwnerAuth,
    signedSlice: slice,
    signature: slice,
) {
    val (_, myAddrHash) = contract.getAddress().getWorkchainAndHash();
    assert (auth.extAddrHash == myAddrHash) throw Errors.WrongExtensionInstance;
    assert (
        isSignatureValid(signedSlice.hash(), signature, self.ownerKey)
    ) throw Errors.InvalidSignature;
    assert (auth.validUntil > blockchain.now()) throw Errors.Expired;
    assert (auth.ownerSeqno == self.ownerSeqno) throw Errors.InvalidSeqno;
}

fun ExtensionStorage.validateSessionAuth(
    self,
    auth: SessionAuth,
    signedSlice: slice,
    signature: slice,
): SessionKeyInfo {
    val lookup = self.sessionKeys.get(auth.pubkey);
    assert (lookup.isFound) throw Errors.InvalidSessionKey;
    val keyInfo = lookup.loadValue();

    val (_, myAddrHash) = contract.getAddress().getWorkchainAndHash();
    assert (auth.extAddrHash == myAddrHash) throw Errors.WrongExtensionInstance;
    assert (
        isSignatureValid(signedSlice.hash(), signature, auth.pubkey)
    ) throw Errors.InvalidSignature;
    assert (keyInfo.validUntil > blockchain.now()) throw Errors.SessionKeyExpired;
    assert (auth.validUntil > blockchain.now()) throw Errors.Expired;
    assert (auth.seqno == keyInfo.seqno) throw Errors.InvalidSeqno;

    return keyInfo;
}

fun ExtensionStorage.bumpSessionSeqno(mutate self, auth: SessionAuth, keyInfo: SessionKeyInfo) {
    self.sessionKeys.set(auth.pubkey, { validUntil: keyInfo.validUntil, seqno: keyInfo.seqno + 1 });
}

fun onExternalMessage(inMsg: slice) {
    val signature = inMsg.getLastBits(SIZE_SIGNATURE);
    val signedSlice = inMsg.removeLastBits(SIZE_SIGNATURE);

    val msg = AllowedExternalMessages.fromSlice(
        signedSlice,
        { throwIfOpcodeDoesNotMatch: Errors.UnsupportedExternalMessage },
    );

    match (msg) {
        // ----- owner-signed management -----
        AddSessionKey => {
            var storage = lazy ExtensionStorage.load();
            storage.validateOwnerAuth(msg.auth.load(), signedSlice, signature);

            acceptExternalMessage();

            storage.ownerSeqno += 1;
            // preserve an existing key's seqno (never rewind the replay guard); only refresh expiry
            val existing = storage.sessionKeys.get(msg.pubkey);
            val seqno: uint32 = existing.isFound ? existing.loadValue().seqno : 0;
            storage.sessionKeys.set(msg.pubkey, { validUntil: msg.validUntil, seqno });
            storage.save();
        }
        RevokeSessionKey => {
            var storage = lazy ExtensionStorage.load();
            storage.validateOwnerAuth(msg.auth.load(), signedSlice, signature);

            acceptExternalMessage();

            storage.ownerSeqno += 1;
            // idempotent; orders already stored by this key stay firable until they expire or are cancelled
            storage.sessionKeys.delete(msg.pubkey);
            storage.save();
        }
        SetTriggerKey => {
            var storage = lazy ExtensionStorage.load();
            storage.validateOwnerAuth(msg.auth.load(), signedSlice, signature);

            acceptExternalMessage();

            storage.ownerSeqno += 1;
            storage.triggerKey = msg.pubkey;
            storage.save();
        }
        StoreOrder => {
            var storage = lazy ExtensionStorage.load();
            storage.validateOwnerAuth(msg.auth.load(), signedSlice, signature);
            assert (storage.openOrderCount < MAX_OPEN_ORDERS) throw Errors.OrderLimitReached;
            assert (!storage.orders.exists(msg.orderId)) throw Errors.OrderAlreadyExists;
            assertSafeOutActionModes(msg.actions);

            acceptExternalMessage();

            storage.ownerSeqno += 1;
            storage.storeOrder(msg.orderId, msg.validUntil, msg.actions);
            storage.save();
        }
        CancelOrder => {
            var storage = lazy ExtensionStorage.load();
            storage.validateOwnerAuth(msg.auth.load(), signedSlice, signature);

            acceptExternalMessage();

            storage.ownerSeqno += 1;
            if (storage.orders.delete(msg.orderId)) {
                storage.openOrderCount -= 1;
            }
            storage.save();
        }
        Uninstall => {
            var storage = lazy ExtensionStorage.load();
            storage.validateOwnerAuth(msg.auth.load(), signedSlice, signature);

            acceptExternalMessage();

            storage.ownerSeqno += 1;
            storage.save();
            commitContractDataAndActions();

            val removeExtensionMsg = createMessage({
                body: W5ExtensionActionRequest {
                    queryId: 0,
                    outActions: null,
                    hasExtraActions: true,
                    extraActions: W5RemoveExtensionExtraAction {
                        addr: contract.getAddress(),
                    }.toCell()
                        .beginParse(),
                },
                bounce: false,
                dest: storage.walletAddress,
                value: 0,
            });
            // SAFETY: owner-authenticated (validateOwnerAuth above). External messages carry
            // no value, so we sweep the extension's own balance back to the wallet on uninstall,
            // leaving nothing stranded in the orphaned contract.
            removeExtensionMsg.send(SEND_MODE_CARRY_ALL_BALANCE);
        }
        // ----- session-key-signed trading -----
        SessionTrade => {
            var storage = lazy ExtensionStorage.load();
            val auth = msg.auth.load();
            val keyInfo = storage.validateSessionAuth(auth, signedSlice, signature);
            assertSafeOutActionModes(msg.outActions);

            acceptExternalMessage();

            // bump and commit the replay guard BEFORE sending, so a later failure
            // can never roll the seqno back and make the message replayable
            storage.bumpSessionSeqno(auth, keyInfo);
            storage.save();
            commitContractDataAndActions();

            forwardOutActionsToWallet(storage.walletAddress, msg.outActions, 0);
        }
        SessionStoreOrder => {
            var storage = lazy ExtensionStorage.load();
            val auth = msg.auth.load();
            val keyInfo = storage.validateSessionAuth(auth, signedSlice, signature);
            assert (storage.openOrderCount < MAX_OPEN_ORDERS) throw Errors.OrderLimitReached;
            assert (!storage.orders.exists(msg.orderId)) throw Errors.OrderAlreadyExists;
            assertSafeOutActionModes(msg.actions);

            acceptExternalMessage();

            storage.bumpSessionSeqno(auth, keyInfo);
            storage.storeOrder(msg.orderId, msg.orderValidUntil, msg.actions);
            storage.save();
        }
        SessionCancelOrder => {
            var storage = lazy ExtensionStorage.load();
            val auth = msg.auth.load();
            val keyInfo = storage.validateSessionAuth(auth, signedSlice, signature);
            assert (storage.orders.exists(msg.orderId)) throw Errors.OrderNotFound;

            acceptExternalMessage();

            storage.bumpSessionSeqno(auth, keyInfo);
            storage.orders.delete(msg.orderId);
            storage.openOrderCount -= 1;
            storage.save();
        }
        // ----- trigger-key-signed order firing -----
        TriggerFire => {
            var storage = lazy ExtensionStorage.load();

            assert (storage.triggerKey != 0) throw Errors.TriggerKeyNotSet;
            val (_, myAddrHash) = contract.getAddress().getWorkchainAndHash();
            assert (msg.extAddrHash == myAddrHash) throw Errors.WrongExtensionInstance;
            assert (
                isSignatureValid(signedSlice.hash(), signature, storage.triggerKey)
            ) throw Errors.InvalidSignature;
            assert (msg.validUntil > blockchain.now()) throw Errors.Expired;

            val lookup = storage.orders.get(msg.orderId);
            assert (lookup.isFound) throw Errors.OrderNotFound;
            val order = lookup.loadValue();
            // bind the fire to this exact order: a stale signature for a reused id fails here
            assert (order.nonce == msg.nonce) throw Errors.WrongOrderNonce;
            assert (order.validUntil > blockchain.now()) throw Errors.OrderExpired;

            acceptExternalMessage();

            // one-shot: delete and commit BEFORE sending; a rebroadcast of the same
            // signed message hits OrderNotFound (or WrongOrderNonce if the id was reused)
            storage.orders.delete(msg.orderId);
            storage.openOrderCount -= 1;
            storage.save();
            commitContractDataAndActions();

            // order.actions had its send modes validated at store time
            forwardOutActionsToWallet(storage.walletAddress, order.actions, msg.orderId);
        }
    }
}

fun ExtensionStorage.storeOrder(mutate self, orderId: uint64, validUntil: uint32, actions: cell) {
    self
        .orders
        .set(
            orderId,
            {
                validUntil,
                nonce: self.orderNonce,
                actions,
            },
        );
    self.orderNonce += 1;
    self.openOrderCount += 1;
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedInternalMessages.fromSlice(in.body);

    match (msg) {
        TopUp => {
            // simply accept funds
        }
        else => {
            // deliberately ignore unknown opcodes, plain transfers, and bounced
            // requests (a bounced fired order stays deleted: one-shot semantics)
        }
    }
}

get fun extensionInfo(): ExtensionStorage {
    return ExtensionStorage.load();
}

// One cheap call for a trading terminal to poll a single session key's lifecycle,
// instead of pulling the whole sessionKeys map. `found == false` means not registered
// (never added or revoked). If found, compare `validUntil` to the current time to
// tell active from expired, and warn the owner to refresh before it lapses.
get fun sessionKeyStatus(pubkey: uint256): SessionKeyStatus {
    val storage = lazy ExtensionStorage.load();
    val lookup = storage.sessionKeys.get(pubkey);
    if (!lookup.isFound) {
        return {
            found: false,
            validUntil: 0,
            seqno: 0,
        };
    }
    val info = lookup.loadValue();
    return {
        found: true,
        validUntil: info.validUntil,
        seqno: info.seqno,
    };
}

// Code version as (major << 16) | (minor << 8) | patch. Lets a client detect an
// outdated installed extension and prompt the owner to uninstall + reinstall
// (new code means a new extension address). Pre-1.2.0 deployments lack this
// get-method — a failed call should be treated as outdated.
get fun version(): int {
    return EXTENSION_VERSION;
}
