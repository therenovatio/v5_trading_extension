import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@wrappers/TradingExtension.gen"
import "@wrappers/utils"
import "utils/common"

// Fires a stored order with the trigger key (webservice role): the extension
// deletes the order and forwards its pre-approved actions to the wallet,
// which executes the transfer from its own balance.
fun main() {
    val extensionAddress = promptW5Address("EXT_ADDRESS", "Enter the installed extension address");
    val extension = TradingExtension.fromAddress(extensionAddress);
    val triggerKey = promptExternalKeyPair("TRIGGER_SEED");

    val orderId = env<int>("ORDER_ID") ?? 1;

    val info = extension.extensionInfo();
    if (info.triggerKey != triggerKey.publicKey) {
        println("Provided key 0x{:x} is not the configured trigger key", triggerKey.publicKey);
        return;
    }
    val orderLookup = info.orders.get(orderId);
    if (!orderLookup.isFound) {
        println("Order {} is not stored", orderId);
        return;
    }
    val nonce = orderLookup.loadValue().nonce;

    val body = createTriggerFireBody(triggerKey, extension.address, orderId, nonce);
    val extResult = extension.sendAnyExternal(body);
    if (!extResult.isAccepted()) {
        println("External message was not accepted");
        return;
    }
    if (extResult.waitForFirstTransaction() == null) {
        println("External message did not produce a transaction");
        return;
    }

    println("Order {} fired — the wallet executed the pre-approved transfer", orderId);
    println("Open orders: {}", extension.extensionInfo().openOrderCount);
}
