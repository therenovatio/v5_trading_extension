import "@acton/crypto"
import "@acton/emulation/network"
import "@acton/emulation/testing"
import "@acton/testing/expect"

import "@contracts/errors"
import "@contracts/types"
import "@contracts/w5-types"
import "@wrappers/TradingExtension.gen"
import "@wrappers/WalletV5.gen"
import "@wrappers/utils"

const EXTENSION_DEPLOY_VALUE = ton("1")
const TEST_START_TIME = 1000
const SESSION_KEY_TTL = 3600
const ORDER_TTL = 7200
const TRADE_VALUE = ton("0.3")

// ===== happy paths =====

get fun `test extension: installs into wallet v5`() {
    val (wallet, _, walletKey, extension) = setupInstalledExtension();

    val extensions = wallet.getExtensions();
    val (_, extensionHash) = extension.address.getWorkchainAndHash();
    expect(extensions.exists(extensionHash)).toEqual(true);

    val info = extension.extensionInfo();
    expect(info.walletAddress).toEqual(wallet.address);
    expect(info.ownerKey).toEqual(walletKey.publicKey);
    expect(info.ownerSeqno).toEqual(0);
    expect(info.triggerKey).toEqual(0);
    expect(info.openOrderCount).toEqual(0);
    expect(info.orderNonce).toEqual(0);
    expect(info.sessionKeys.isEmpty()).toEqual(true);
    expect(info.orders.isEmpty()).toEqual(true);
}

get fun `test extension: reports its code version`() {
    val (_, _, _, extension) = setupInstalledExtension();
    expect(extension.version()).toEqual(EXTENSION_VERSION);
}

get fun `test owner: adds and revokes session keys, multiple keys coexist`() {
    val (_, _, walletKey, extension) = setupInstalledExtension();
    val keyA = crypto.generateKeyPair();
    val keyB = crypto.generateKeyPair();

    addSessionKey(walletKey, extension, keyA);
    addSessionKey(walletKey, extension, keyB);

    var info = extension.extensionInfo();
    expect(info.sessionKeys.exists(keyA.publicKey)).toEqual(true);
    expect(info.sessionKeys.exists(keyB.publicKey)).toEqual(true);
    expect(info.sessionKeys.mustGet(keyA.publicKey).seqno).toEqual(0);
    expect(info.sessionKeys.mustGet(keyA.publicKey).validUntil).toEqual(
        TEST_START_TIME + SESSION_KEY_TTL,
    );
    expect(info.ownerSeqno).toEqual(2);

    val receipt = ownerRevokeSessionKey(walletKey, extension, keyA.publicKey);
    expect(receipt).toBeAccepted();

    info = extension.extensionInfo();
    expect(info.sessionKeys.exists(keyA.publicKey)).toEqual(false);
    expect(info.sessionKeys.exists(keyB.publicKey)).toEqual(true);
}

get fun `test session: trade makes the wallet actually pay the recipient`() {
    val (wallet, _, _, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");
    val balanceBefore = testing.getAccountBalance(recipient.address);

    val result = sendSessionTrade(extension, sessionKey, 0, recipient.address, TRADE_VALUE);
    val receipt = result.unwrap();

    expect(receipt).toHaveSuccessfulTx<W5ExtensionActionRequest>({
        from: extension.address,
        to: wallet.address,
    });
    expect(receipt).toHaveSuccessfulTx({
        from: wallet.address,
        to: recipient.address,
        value: TRADE_VALUE,
    });

    val balanceAfter = testing.getAccountBalance(recipient.address);
    expect((balanceAfter - balanceBefore) as int).toBeApproxEqAbs(TRADE_VALUE, ton("0.001"));

    expect(extension.extensionInfo().sessionKeys.mustGet(sessionKey.publicKey).seqno).toEqual(1);

    // seqno advanced: next trade with seqno 1 works too
    sendSessionTrade(extension, sessionKey, 1, recipient.address, TRADE_VALUE).unwrap();
    expect(extension.extensionInfo().sessionKeys.mustGet(sessionKey.publicKey).seqno).toEqual(2);
}

get fun `test session: two keys trade independently with separate seqnos`() {
    val (_, _, walletKey, extension, keyA) = setupWithSessionKey();
    val keyB = crypto.generateKeyPair();
    addSessionKey(walletKey, extension, keyB);
    val recipient = testing.treasury("recipient");

    sendSessionTrade(extension, keyA, 0, recipient.address, TRADE_VALUE).unwrap();
    sendSessionTrade(extension, keyB, 0, recipient.address, TRADE_VALUE).unwrap();

    val info = extension.extensionInfo();
    expect(info.sessionKeys.mustGet(keyA.publicKey).seqno).toEqual(1);
    expect(info.sessionKeys.mustGet(keyB.publicKey).seqno).toEqual(1);
}

get fun `test session: forwards a payload-carrying action (DEX swap mechanism)`() {
    // A swap is just a session trade whose out-action carries an aggregator payload
    // to a DEX vault. Verify the extension forwards the value AND the body to the dest.
    val (wallet, _, _, extension, sessionKey) = setupWithSessionKey();
    val vault = testing.treasury("dex_vault");
    val balanceBefore = testing.getAccountBalance(vault.address);

    // stand-in for a DeDust swap payload (opcode + params)
    val swapPayload = beginCell().storeUint(0xe3a0d482, 32).storeUint(12345, 64).endCell();
    val outActions = buildOutActionsCell(
        [
            sendMsgActionWithBody(
                vault.address,
                ton("1.25"),
                swapPayload,
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
            ),
        ],
    );
    val body = createSessionTradeBody(sessionKey, extension.address, 0, outActions);
    val receipt = extension.sendAnyExternal(body).unwrap();

    expect(receipt).toHaveSuccessfulTx<W5ExtensionActionRequest>({
        from: extension.address,
        to: wallet.address,
    });
    // the wallet paid the vault the swap value from its own balance
    expect(receipt).toHaveSuccessfulTx({
        from: wallet.address,
        to: vault.address,
        value: ton("1.25"),
    });
    val balanceAfter = testing.getAccountBalance(vault.address);
    expect((balanceAfter - balanceBefore) as int).toBeApproxEqAbs(ton("1.25"), ton("0.01"));
}

get fun `test owner: stores and cancels an order`() {
    val (_, _, walletKey, extension) = setupInstalledExtension();
    val recipient = testing.treasury("recipient");

    val storeReceipt = ownerStoreOrder(walletKey, extension, 42, recipient.address);
    expect(storeReceipt).toBeAccepted();

    var info = extension.extensionInfo();
    expect(info.openOrderCount).toEqual(1);
    expect(info.orders.exists(42)).toEqual(true);
    expect(info.orders.mustGet(42).validUntil).toEqual(TEST_START_TIME + ORDER_TTL);
    expect(info.orders.mustGet(42).nonce).toEqual(0);
    expect(info.orderNonce).toEqual(1);

    val cancelReceipt = ownerCancelOrder(walletKey, extension, 42);
    expect(cancelReceipt).toBeAccepted();

    info = extension.extensionInfo();
    expect(info.openOrderCount).toEqual(0);
    expect(info.orders.exists(42)).toEqual(false);
}

get fun `test session: stores and cancels an order without owner confirmation`() {
    val (_, _, _, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    val storeBody = createSessionStoreOrderBody(
        sessionKey,
        extension.address,
        0,
        7,
        TEST_START_TIME + ORDER_TTL,
        singleTransferActions(recipient.address, TRADE_VALUE),
    );
    extension.sendAnyExternal(storeBody).unwrap();

    var info = extension.extensionInfo();
    expect(info.openOrderCount).toEqual(1);
    expect(info.orders.exists(7)).toEqual(true);
    expect(info.sessionKeys.mustGet(sessionKey.publicKey).seqno).toEqual(1);

    val cancelBody = createSessionCancelOrderBody(sessionKey, extension.address, 1, 7);
    extension.sendAnyExternal(cancelBody).unwrap();

    info = extension.extensionInfo();
    expect(info.openOrderCount).toEqual(0);
    expect(info.orders.exists(7)).toEqual(false);
    expect(info.sessionKeys.mustGet(sessionKey.publicKey).seqno).toEqual(2);
}

get fun `test trigger: fires a stored order, wallet pays, order is deleted`() {
    val (wallet, _, walletKey, extension) = setupInstalledExtension();
    val triggerKey = crypto.generateKeyPair();
    setTriggerKey(walletKey, extension, triggerKey);
    val recipient = testing.treasury("recipient");
    ownerStoreOrder(walletKey, extension, 42, recipient.address).unwrap();
    val nonce = extension.extensionInfo().orders.mustGet(42).nonce;

    val balanceBefore = testing.getAccountBalance(recipient.address);
    val body = createTriggerFireBody(triggerKey, extension.address, 42, nonce);
    val receipt = extension.sendAnyExternal(body).unwrap();

    expect(receipt).toHaveSuccessfulTx<W5ExtensionActionRequest>({
        from: extension.address,
        to: wallet.address,
    });
    expect(receipt).toHaveSuccessfulTx({
        from: wallet.address,
        to: recipient.address,
        value: TRADE_VALUE,
    });
    val balanceAfter = testing.getAccountBalance(recipient.address);
    expect((balanceAfter - balanceBefore) as int).toBeApproxEqAbs(TRADE_VALUE, ton("0.001"));

    val info = extension.extensionInfo();
    expect(info.orders.exists(42)).toEqual(false);
    expect(info.openOrderCount).toEqual(0);
}

get fun `test owner: uninstall removes extension from wallet`() {
    val (wallet, _, walletKey, extension) = setupInstalledExtension();

    val receipt = ownerUninstall(walletKey, extension).unwrap();
    expect(receipt).toHaveSuccessfulTx<W5ExtensionActionRequest>({
        from: extension.address,
        to: wallet.address,
    });

    val extensions = wallet.getExtensions();
    val (_, extensionHash) = extension.address.getWorkchainAndHash();
    expect(extensions.exists(extensionHash)).toEqual(false);
}

// ===== H-1 regression: session key cannot escalate to management =====

get fun `test security: session key cannot add a management key by looping through the wallet`() {
    val (_, _, _, extension, sessionKey) = setupWithSessionKey();
    val attackerKey = crypto.generateKeyPair();

    // Craft the exact old exploit: a trade whose out-action makes the wallet send an
    // AddSessionKey-opcode message BACK to the extension. Management is now external-signed
    // only, so this internal message hits no handler and is silently ignored.
    val maliciousBody = beginCell()
        .storeUint(0x53455301, 32) // AddSessionKey opcode
        .storeRef(beginCell().endCell()) // where the OwnerAuth ref would be
        .storeUint(attackerKey.publicKey, 256)
        .storeUint(0xFFFFFFFF, 32) // far-future validUntil
        .endCell();
    val innerMsg = createMessage({
        bounce: false,
        value: ton("0.05"),
        dest: extension.address,
        body: maliciousBody,
    });
    val loopAction = buildOutActionsCell(
        [
            SendAction {
                mode: SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
                messageCell: innerMsg.messageCell,
            },
        ],
    );
    val trade = createSessionTradeBody(sessionKey, extension.address, 0, loopAction);
    // the trade itself is a valid session action, so it is accepted and forwarded
    extension.sendAnyExternal(trade).unwrap();

    // ...but the looped-back message did NOT register the attacker's key
    expect(extension.extensionInfo().sessionKeys.exists(attackerKey.publicKey)).toEqual(false);
}

get fun `test security: management signed by a non-owner key is rejected`() {
    val (_, _, _, extension) = setupInstalledExtension();
    val strangerKey = crypto.generateKeyPair();
    val attackerSession = crypto.generateKeyPair();

    // stranger tries to add a session key with the correct ownerSeqno but the wrong key
    val body = createAddSessionKeyBody(
        strangerKey,
        extension.address,
        0,
        attackerSession.publicKey,
        TEST_START_TIME + SESSION_KEY_TTL,
    );
    val result = extension.sendAnyExternal(body);
    expect(result).toBeNotAccepted();
    expect(result).toHaveExternalVmExitCode(Errors.InvalidSignature as int);
    expect(extension.extensionInfo().sessionKeys.isEmpty()).toEqual(true);
}

get fun `test security: management with a stale ownerSeqno is rejected`() {
    val (_, _, walletKey, extension) = setupInstalledExtension();
    val keyA = crypto.generateKeyPair();
    val keyB = crypto.generateKeyPair();

    addSessionKey(walletKey, extension, keyA); // ownerSeqno 0 -> 1

    // reuse ownerSeqno 0 (already consumed)
    val stale = createAddSessionKeyBody(
        walletKey,
        extension.address,
        0,
        keyB.publicKey,
        TEST_START_TIME + SESSION_KEY_TTL,
    );
    val result = extension.sendAnyExternal(stale);
    expect(result).toBeNotAccepted();
    expect(result).toHaveExternalVmExitCode(Errors.InvalidSeqno as int);
    expect(extension.extensionInfo().sessionKeys.exists(keyB.publicKey)).toEqual(false);
}

// ===== F-1 regression: unsafe send modes are rejected =====

get fun `test security: session trade with carry-all or destroy mode is rejected`() {
    val (_, _, _, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    val carryAll = createSessionTradeBody(
        sessionKey,
        extension.address,
        0,
        buildOutActionsCell(
            [sendMsgActionWithMode(recipient.address, 0, SEND_MODE_CARRY_ALL_BALANCE)],
        ),
    );
    val r1 = extension.sendAnyExternal(carryAll);
    expect(r1).toBeNotAccepted();
    expect(r1).toHaveExternalVmExitCode(Errors.UnsafeSendMode as int);

    val destroy = createSessionTradeBody(
        sessionKey,
        extension.address,
        0,
        buildOutActionsCell(
            [sendMsgActionWithMode(recipient.address, TRADE_VALUE, SEND_MODE_DESTROY)],
        ),
    );
    val r2 = extension.sendAnyExternal(destroy);
    expect(r2).toBeNotAccepted();
    expect(r2).toHaveExternalVmExitCode(Errors.UnsafeSendMode as int);

    // seqno untouched (rejected before accept)
    expect(extension.extensionInfo().sessionKeys.mustGet(sessionKey.publicKey).seqno).toEqual(0);
}

get fun `test security: storing an order with an unsafe send mode is rejected`() {
    val (_, _, _, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    val body = createSessionStoreOrderBody(
        sessionKey,
        extension.address,
        0,
        7,
        TEST_START_TIME + ORDER_TTL,
        buildOutActionsCell(
            [sendMsgActionWithMode(recipient.address, 0, SEND_MODE_CARRY_ALL_BALANCE)],
        ),
    );
    val result = extension.sendAnyExternal(body);
    expect(result).toBeNotAccepted();
    expect(result).toHaveExternalVmExitCode(Errors.UnsafeSendMode as int);
    expect(extension.extensionInfo().openOrderCount).toEqual(0);
}

// ===== M-1 regression: trigger replay via orderId reuse =====

get fun `test security: stale trigger signature cannot fire a re-stored order id`() {
    val (_, _, walletKey, extension) = setupInstalledExtension();
    val triggerKey = crypto.generateKeyPair();
    setTriggerKey(walletKey, extension, triggerKey);
    val recipient = testing.treasury("recipient");

    ownerStoreOrder(walletKey, extension, 42, recipient.address).unwrap();
    val nonce0 = extension.extensionInfo().orders.mustGet(42).nonce;

    // capture a valid trigger for order 42 (nonce 0) and fire it
    val staleBody = createTriggerFireBody(triggerKey, extension.address, 42, nonce0);
    extension.sendAnyExternal(staleBody).unwrap();
    expect(extension.extensionInfo().orders.exists(42)).toEqual(false);

    // re-store id 42 (gets a fresh nonce)
    ownerStoreOrder(walletKey, extension, 42, recipient.address).unwrap();
    val nonce1 = extension.extensionInfo().orders.mustGet(42).nonce;
    expect(nonce1).toNotEqual(nonce0);

    // replaying the captured trigger fails: the nonce no longer matches
    val replay = extension.sendAnyExternal(staleBody);
    expect(replay).toBeNotAccepted();
    expect(replay).toHaveExternalVmExitCode(Errors.WrongOrderNonce as int);
    expect(extension.extensionInfo().orders.exists(42)).toEqual(true);

    // a fresh trigger with the current nonce still works
    val freshBody = createTriggerFireBody(triggerKey, extension.address, 42, nonce1);
    extension.sendAnyExternal(freshBody).unwrap();
    expect(extension.extensionInfo().orders.exists(42)).toEqual(false);
}

get fun `test security: replayed trigger fire hits OrderNotFound`() {
    val (_, _, walletKey, extension) = setupInstalledExtension();
    val triggerKey = crypto.generateKeyPair();
    setTriggerKey(walletKey, extension, triggerKey);
    val recipient = testing.treasury("recipient");
    ownerStoreOrder(walletKey, extension, 42, recipient.address).unwrap();
    val nonce = extension.extensionInfo().orders.mustGet(42).nonce;

    val body = createTriggerFireBody(triggerKey, extension.address, 42, nonce);
    extension.sendAnyExternal(body).unwrap();

    val replay = extension.sendAnyExternal(body);
    expect(replay).toBeNotAccepted();
    expect(replay).toHaveExternalVmExitCode(Errors.OrderNotFound as int);
}

// ===== M-2 regression: re-adding a session key preserves seqno =====

get fun `test security: re-adding a session key does not reset its seqno`() {
    val (_, _, walletKey, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    // spend seqno 0
    val spentTrade = createSessionTradeBody(
        sessionKey,
        extension.address,
        0,
        singleTransferActions(recipient.address, TRADE_VALUE),
    );
    extension.sendAnyExternal(spentTrade).unwrap();
    expect(extension.extensionInfo().sessionKeys.mustGet(sessionKey.publicKey).seqno).toEqual(1);

    // owner re-adds the same key to refresh its expiry
    addSessionKey(walletKey, extension, sessionKey);
    val info = extension.extensionInfo();
    expect(info.sessionKeys.mustGet(sessionKey.publicKey).seqno).toEqual(1); // NOT reset to 0

    // replaying the already-spent seqno-0 trade still fails
    val replay = extension.sendAnyExternal(spentTrade);
    expect(replay).toBeNotAccepted();
    expect(replay).toHaveExternalVmExitCode(Errors.InvalidSeqno as int);

    // trading with the current seqno still works
    sendSessionTrade(extension, sessionKey, 1, recipient.address, TRADE_VALUE).unwrap();
}

// ===== sessionKeyStatus getter (lifecycle monitoring) =====

get fun `test getter: sessionKeyStatus reports registered, expired, and revoked`() {
    val (_, _, walletKey, extension, sessionKey) = setupWithSessionKey();
    val unknownKey = crypto.generateKeyPair();

    // unknown key: not found
    val unknown = extension.sessionKeyStatus(unknownKey.publicKey);
    expect(unknown.found).toEqual(false);

    // registered key: found, correct expiry, seqno 0
    var status = extension.sessionKeyStatus(sessionKey.publicKey);
    expect(status.found).toEqual(true);
    expect(status.validUntil).toEqual(TEST_START_TIME + SESSION_KEY_TTL);
    expect(status.seqno).toEqual(0);

    // still "found" after expiry (caller compares validUntil to now to detect it)
    testing.setNow(TEST_START_TIME + SESSION_KEY_TTL + 1);
    status = extension.sessionKeyStatus(sessionKey.publicKey);
    expect(status.found).toEqual(true);
    expect(status.validUntil <= testing.getNow()).toEqual(true);

    // revoked: not found
    testing.setNow(TEST_START_TIME);
    ownerRevokeSessionKey(walletKey, extension, sessionKey.publicKey).unwrap();
    expect(extension.sessionKeyStatus(sessionKey.publicKey).found).toEqual(false);
}

get fun `test getter: sessionKeyStatus reflects seqno and refreshed expiry`() {
    val (_, _, walletKey, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    sendSessionTrade(extension, sessionKey, 0, recipient.address, TRADE_VALUE).unwrap();
    expect(extension.sessionKeyStatus(sessionKey.publicKey).seqno).toEqual(1);

    // refresh (re-add) advances validUntil but preserves seqno
    val newValidUntil = TEST_START_TIME + 100 + SESSION_KEY_TTL;
    val refresh = createAddSessionKeyBody(
        walletKey,
        extension.address,
        extension.extensionInfo().ownerSeqno,
        sessionKey.publicKey,
        newValidUntil,
    );
    extension.sendAnyExternal(refresh).unwrap();
    val status = extension.sessionKeyStatus(sessionKey.publicKey);
    expect(status.validUntil).toEqual(newValidUntil);
    expect(status.seqno).toEqual(1);
}

// ===== negative paths: session auth =====

get fun `test session: expired key cannot trade or store orders`() {
    val (_, _, _, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    testing.setNow(TEST_START_TIME + SESSION_KEY_TTL + 1);

    val trade = sendSessionTrade(extension, sessionKey, 0, recipient.address, TRADE_VALUE);
    expect(trade).toBeNotAccepted();
    expect(trade).toHaveExternalVmExitCode(Errors.SessionKeyExpired as int);

    val storeBody = createSessionStoreOrderBody(
        sessionKey,
        extension.address,
        0,
        7,
        TEST_START_TIME + SESSION_KEY_TTL + ORDER_TTL,
        singleTransferActions(recipient.address, TRADE_VALUE),
    );
    val store = extension.sendAnyExternal(storeBody);
    expect(store).toBeNotAccepted();
    expect(store).toHaveExternalVmExitCode(Errors.SessionKeyExpired as int);
}

get fun `test session: revoked key is rejected`() {
    val (_, _, walletKey, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    ownerRevokeSessionKey(walletKey, extension, sessionKey.publicKey).unwrap();

    val trade = sendSessionTrade(extension, sessionKey, 0, recipient.address, TRADE_VALUE);
    expect(trade).toBeNotAccepted();
    expect(trade).toHaveExternalVmExitCode(Errors.InvalidSessionKey as int);
}

get fun `test session: signature by another key over a valid pubkey is rejected`() {
    val (_, _, _, extension, sessionKey) = setupWithSessionKey();
    val attacker = crypto.generateKeyPair();
    val recipient = testing.treasury("recipient");

    // payload claims the legit session pubkey, but is signed by the attacker
    val payload = SessionTrade {
        auth: makeSessionAuth(sessionKey, extension.address, 0),
        outActions: singleTransferActions(recipient.address, TRADE_VALUE),
    };
    val body = signExternalBody(attacker, payload.toCell());

    val result = extension.sendAnyExternal(body);
    expect(result).toBeNotAccepted();
    expect(result).toHaveExternalVmExitCode(Errors.InvalidSignature as int);
}

get fun `test session: replayed seqno is rejected`() {
    val (_, _, _, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    val body = createSessionTradeBody(
        sessionKey,
        extension.address,
        0,
        singleTransferActions(recipient.address, TRADE_VALUE),
    );
    extension.sendAnyExternal(body).unwrap();

    val replay = extension.sendAnyExternal(body);
    expect(replay).toBeNotAccepted();
    expect(replay).toHaveExternalVmExitCode(Errors.InvalidSeqno as int);
}

get fun `test session: message bound to another extension instance is rejected`() {
    val (wallet, _, _, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");

    // extAddrHash points at the wallet, not at this extension instance
    val body = createSessionTradeBody(
        sessionKey,
        wallet.address,
        0,
        singleTransferActions(recipient.address, TRADE_VALUE),
    );
    val result = extension.sendAnyExternal(body);
    expect(result).toBeNotAccepted();
    expect(result).toHaveExternalVmExitCode(Errors.WrongExtensionInstance as int);
}

// ===== negative paths: trigger =====

get fun `test trigger: expired order cannot be fired`() {
    val (_, _, walletKey, extension) = setupInstalledExtension();
    val triggerKey = crypto.generateKeyPair();
    setTriggerKey(walletKey, extension, triggerKey);
    val recipient = testing.treasury("recipient");
    ownerStoreOrder(walletKey, extension, 42, recipient.address).unwrap();
    val nonce = extension.extensionInfo().orders.mustGet(42).nonce;

    testing.setNow(TEST_START_TIME + ORDER_TTL + 1);

    val body = createTriggerFireBody(triggerKey, extension.address, 42, nonce);
    val result = extension.sendAnyExternal(body);
    expect(result).toBeNotAccepted();
    expect(result).toHaveExternalVmExitCode(Errors.OrderExpired as int);
}

get fun `test trigger: fire without a configured trigger key is rejected`() {
    val (_, _, walletKey, extension) = setupInstalledExtension();
    val recipient = testing.treasury("recipient");
    ownerStoreOrder(walletKey, extension, 42, recipient.address).unwrap();
    val nonce = extension.extensionInfo().orders.mustGet(42).nonce;

    val someKey = crypto.generateKeyPair();
    val body = createTriggerFireBody(someKey, extension.address, 42, nonce);
    val result = extension.sendAnyExternal(body);
    expect(result).toBeNotAccepted();
    expect(result).toHaveExternalVmExitCode(Errors.TriggerKeyNotSet as int);
}

get fun `test trigger: wrong key cannot fire, trigger key cannot trade`() {
    val (_, _, walletKey, extension) = setupInstalledExtension();
    val triggerKey = crypto.generateKeyPair();
    val strangerKey = crypto.generateKeyPair();
    setTriggerKey(walletKey, extension, triggerKey);
    val recipient = testing.treasury("recipient");
    ownerStoreOrder(walletKey, extension, 42, recipient.address).unwrap();
    val nonce = extension.extensionInfo().orders.mustGet(42).nonce;

    // stranger's signature does not verify against the stored trigger key
    val strangerFire = extension.sendAnyExternal(
        createTriggerFireBody(strangerKey, extension.address, 42, nonce),
    );
    expect(strangerFire).toBeNotAccepted();
    expect(strangerFire).toHaveExternalVmExitCode(Errors.InvalidSignature as int);

    // trigger key is not a session key: it cannot submit trades
    val triggerTrade = sendSessionTrade(extension, triggerKey, 0, recipient.address, TRADE_VALUE);
    expect(triggerTrade).toBeNotAccepted();
    expect(triggerTrade).toHaveExternalVmExitCode(Errors.InvalidSessionKey as int);
}

// ===== negative paths: orders =====

get fun `test orders: cap of 100 open orders is enforced on owner and session paths`() {
    testing.setNow(TEST_START_TIME);
    val walletKey = crypto.generateKeyPair();
    val (wallet, admin) = deployWalletWithKey(walletKey);
    val sessionKey = crypto.generateKeyPair();
    val recipient = testing.treasury("recipient");

    // start with a full order book baked into initial storage
    var orders: map<uint64, OrderInfo> = [];
    var sessionKeys: map<uint256, SessionKeyInfo> = [];
    sessionKeys.set(
        sessionKey.publicKey,
        { validUntil: TEST_START_TIME + SESSION_KEY_TTL, seqno: 0 },
    );
    var i: uint64 = 1;
    while (i <= MAX_OPEN_ORDERS) {
        orders.set(
            i,
            {
                validUntil: TEST_START_TIME + ORDER_TTL,
                nonce: 0,
                actions: singleTransferActions(recipient.address, TRADE_VALUE),
            },
        );
        i += 1;
    }
    val extension = TradingExtension.fromStorage({
        walletAddress: wallet.address,
        ownerKey: walletKey.publicKey,
        ownerSeqno: 0,
        triggerKey: 0,
        openOrderCount: MAX_OPEN_ORDERS,
        orderNonce: MAX_OPEN_ORDERS,
        sessionKeys,
        orders,
    });
    val deployReceipt = extension.deploy(
        admin.address,
        { value: EXTENSION_DEPLOY_VALUE, bounce: false },
    );
    expect(deployReceipt).toHaveSuccessfulDeploy({ to: extension.address });
    val installReceipt = addExtensionSigned(wallet, admin.address, extension.address, walletKey, 0);
    expect(installReceipt).toHaveSuccessfulTx({ from: admin.address, to: wallet.address });

    // owner path: the 101st order is rejected
    val ownerStore = ownerStoreOrder(walletKey, extension, 101, recipient.address);
    expect(ownerStore).toBeNotAccepted();
    expect(ownerStore).toHaveExternalVmExitCode(Errors.OrderLimitReached as int);

    // session path: also rejected
    val sessionStore = extension.sendAnyExternal(
        createSessionStoreOrderBody(
            sessionKey,
            extension.address,
            0,
            101,
            TEST_START_TIME + ORDER_TTL,
            singleTransferActions(recipient.address, TRADE_VALUE),
        ),
    );
    expect(sessionStore).toBeNotAccepted();
    expect(sessionStore).toHaveExternalVmExitCode(Errors.OrderLimitReached as int);

    expect(extension.extensionInfo().openOrderCount).toEqual(MAX_OPEN_ORDERS);

    // cancelling one frees a slot
    extension
        .sendAnyExternal(
            createSessionCancelOrderBody(sessionKey, extension.address, 0, 1),
        )
        .unwrap();
    extension
        .sendAnyExternal(
            createSessionStoreOrderBody(
                sessionKey,
                extension.address,
                1,
                101,
                TEST_START_TIME + ORDER_TTL,
                singleTransferActions(recipient.address, TRADE_VALUE),
            ),
        )
        .unwrap();
    expect(extension.extensionInfo().openOrderCount).toEqual(MAX_OPEN_ORDERS);
}

get fun `test orders: duplicate orderId is rejected on both paths`() {
    val (_, _, walletKey, extension, sessionKey) = setupWithSessionKey();
    val recipient = testing.treasury("recipient");
    ownerStoreOrder(walletKey, extension, 42, recipient.address).unwrap();

    val ownerStore = ownerStoreOrder(walletKey, extension, 42, recipient.address);
    expect(ownerStore).toBeNotAccepted();
    expect(ownerStore).toHaveExternalVmExitCode(Errors.OrderAlreadyExists as int);

    val sessionStore = extension.sendAnyExternal(
        createSessionStoreOrderBody(
            sessionKey,
            extension.address,
            0,
            42,
            TEST_START_TIME + ORDER_TTL,
            singleTransferActions(recipient.address, TRADE_VALUE),
        ),
    );
    expect(sessionStore).toBeNotAccepted();
    expect(sessionStore).toHaveExternalVmExitCode(Errors.OrderAlreadyExists as int);

    expect(extension.extensionInfo().openOrderCount).toEqual(1);
}

get fun `test orders: cancelling a missing order fails on session path, is a no-op for owner`() {
    val (_, _, walletKey, extension, sessionKey) = setupWithSessionKey();

    val sessionCancel = extension.sendAnyExternal(
        createSessionCancelOrderBody(sessionKey, extension.address, 0, 999),
    );
    expect(sessionCancel).toBeNotAccepted();
    expect(sessionCancel).toHaveExternalVmExitCode(Errors.OrderNotFound as int);

    // owner cancel of a missing order is deliberately idempotent (accepted, no-op)
    val ownerCancel = ownerCancelOrder(walletKey, extension, 999);
    expect(ownerCancel).toBeAccepted();
    expect(extension.extensionInfo().openOrderCount).toEqual(0);
}

// ===== helpers =====

fun setupInstalledExtension(): (WalletV5, Treasury, KeyPair, TradingExtension) {
    testing.setNow(TEST_START_TIME);

    val walletKey = crypto.generateKeyPair();
    val (wallet, admin) = deployWalletWithKey(walletKey);

    val extension = TradingExtension.fromStorage({
        walletAddress: wallet.address,
        ownerKey: walletKey.publicKey,
        ownerSeqno: 0,
        triggerKey: 0,
        openOrderCount: 0,
        orderNonce: 0,
        sessionKeys: [],
        orders: [],
    });
    val deployReceipt = extension.deploy(
        admin.address,
        { value: EXTENSION_DEPLOY_VALUE, bounce: false },
    );
    expect(deployReceipt).toHaveSuccessfulDeploy({ to: extension.address });

    val installReceipt = addExtensionSigned(wallet, admin.address, extension.address, walletKey, 0);
    expect(installReceipt).toHaveSuccessfulTx({ from: admin.address, to: wallet.address });

    return (wallet, admin, walletKey, extension);
}

fun setupWithSessionKey(): (WalletV5, Treasury, KeyPair, TradingExtension, KeyPair) {
    val (wallet, admin, walletKey, extension) = setupInstalledExtension();
    val sessionKey = crypto.generateKeyPair();
    addSessionKey(walletKey, extension, sessionKey);
    return (wallet, admin, walletKey, extension, sessionKey);
}

// ----- owner-signed management (owner key == wallet key) -----

fun ownerAddSessionKeyBody(walletKey: KeyPair, extension: TradingExtension, pubkey: uint256): cell {
    return createAddSessionKeyBody(
        walletKey,
        extension.address,
        extension.extensionInfo().ownerSeqno,
        pubkey,
        TEST_START_TIME + SESSION_KEY_TTL,
    );
}

fun addSessionKey(walletKey: KeyPair, extension: TradingExtension, sessionKey: KeyPair) {
    val result = extension.sendAnyExternal(
        ownerAddSessionKeyBody(walletKey, extension, sessionKey.publicKey),
    );
    expect(result).toBeAccepted();
}

fun ownerRevokeSessionKey(
    walletKey: KeyPair,
    extension: TradingExtension,
    pubkey: uint256,
): ExternalSendResult {
    return extension.sendAnyExternal(
        createRevokeSessionKeyBody(
            walletKey,
            extension.address,
            extension.extensionInfo().ownerSeqno,
            pubkey,
        ),
    );
}

fun setTriggerKey(walletKey: KeyPair, extension: TradingExtension, triggerKey: KeyPair) {
    val result = extension.sendAnyExternal(
        createSetTriggerKeyBody(
            walletKey,
            extension.address,
            extension.extensionInfo().ownerSeqno,
            triggerKey.publicKey,
        ),
    );
    expect(result).toBeAccepted();
}

fun ownerStoreOrder(
    walletKey: KeyPair,
    extension: TradingExtension,
    orderId: uint64,
    recipient: address,
): ExternalSendResult {
    return extension.sendAnyExternal(
        createOwnerStoreOrderBody(
            walletKey,
            extension.address,
            extension.extensionInfo().ownerSeqno,
            orderId,
            TEST_START_TIME + ORDER_TTL,
            singleTransferActions(recipient, TRADE_VALUE),
        ),
    );
}

fun ownerCancelOrder(
    walletKey: KeyPair,
    extension: TradingExtension,
    orderId: uint64,
): ExternalSendResult {
    return extension.sendAnyExternal(
        createOwnerCancelOrderBody(
            walletKey,
            extension.address,
            extension.extensionInfo().ownerSeqno,
            orderId,
        ),
    );
}

fun ownerUninstall(walletKey: KeyPair, extension: TradingExtension): ExternalSendResult {
    return extension.sendAnyExternal(
        createUninstallBody(
            walletKey,
            extension.address,
            extension.extensionInfo().ownerSeqno,
        ),
    );
}

fun singleTransferActions(recipient: address, amount: coins): cell {
    return buildOutActionsCell([sendMsgAction(recipient, amount)]);
}

fun sendSessionTrade(
    extension: TradingExtension,
    sessionKey: KeyPair,
    seqno: int,
    recipient: address,
    amount: coins,
): ExternalSendResult {
    val body = createSessionTradeBody(
        sessionKey,
        extension.address,
        seqno,
        singleTransferActions(recipient, amount),
    );
    return extension.sendAnyExternal(body);
}
