import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@wrappers/TradingExtension.gen"
import "@wrappers/utils"
import "utils/common"

// Cancels a stored order, signed by a session key — no owner confirmation needed.
fun main() {
    val extensionAddress = promptW5Address("EXT_ADDRESS", "Enter the installed extension address");
    val extension = TradingExtension.fromAddress(extensionAddress);
    val sessionKey = promptExternalKeyPair("SESSION_SEED");

    val orderId = env<int>("ORDER_ID") ?? 1;

    val info = extension.extensionInfo();
    val keyLookup = info.sessionKeys.get(sessionKey.publicKey);
    if (!keyLookup.isFound) {
        println(
            "Session key 0x{:x} is not registered — run add-session-key first",
            sessionKey.publicKey,
        );
        return;
    }
    if (!info.orders.exists(orderId)) {
        println("Order {} is not stored", orderId);
        return;
    }
    val seqno = keyLookup.loadValue().seqno;

    val body = createSessionCancelOrderBody(sessionKey, extension.address, seqno, orderId);
    val extResult = extension.sendAnyExternal(body);
    if (!extResult.isAccepted()) {
        println("External message was not accepted");
        return;
    }
    if (extResult.waitForFirstTransaction() == null) {
        println("External message did not produce a transaction");
        return;
    }

    println("Order {} cancelled", orderId);
    println("Open orders: {}", extension.extensionInfo().openOrderCount);
}
