import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@wrappers/TradingExtension.gen"
import "@wrappers/utils"
import "utils/common"

const DEFAULT_ORDER_TTL = 3600
const DEFAULT_ORDER_AMOUNT = ton("0.05")

// Stores a limit order signed by a session key — no owner confirmation needed.
// The order is a pre-approved transfer of ORDER_AMOUNT (nanotons) to ORDER_TARGET,
// firable by the trigger key until it expires.
fun main() {
    val extensionAddress = promptW5Address("EXT_ADDRESS", "Enter the installed extension address");
    val extension = TradingExtension.fromAddress(extensionAddress);
    val sessionKey = promptExternalKeyPair("SESSION_SEED");

    val orderId = env<int>("ORDER_ID") ?? 1;
    val orderTtl = env<int>("ORDER_TTL_SECS") ?? DEFAULT_ORDER_TTL;
    val target = promptW5Address("ORDER_TARGET", "Enter the transfer destination address");
    val amount = env<coins>("ORDER_AMOUNT") ?? DEFAULT_ORDER_AMOUNT;

    val info = extension.extensionInfo();
    val keyLookup = info.sessionKeys.get(sessionKey.publicKey);
    if (!keyLookup.isFound) {
        println(
            "Session key 0x{:x} is not registered — run add-session-key first",
            sessionKey.publicKey,
        );
        return;
    }
    val seqno = keyLookup.loadValue().seqno;
    val orderValidUntil = blockchain.now() + orderTtl;

    val body = createSessionStoreOrderBody(
        sessionKey,
        extension.address,
        seqno,
        orderId,
        orderValidUntil,
        buildOutActionsCell([sendMsgAction(target, amount)]),
    );
    val extResult = extension.sendAnyExternal(body);
    if (!extResult.isAccepted()) {
        println("External message was not accepted");
        return;
    }
    if (extResult.waitForFirstTransaction() == null) {
        println("External message did not produce a transaction");
        return;
    }

    println(
        "Order {} stored: {:ton} TON -> {}, expires {}",
        orderId,
        amount,
        target,
        orderValidUntil,
    );
    println("Open orders: {}", extension.extensionInfo().openOrderCount);
}
