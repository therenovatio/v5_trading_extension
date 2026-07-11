import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@wrappers/TradingExtension.gen"
import "@wrappers/utils"
import "utils/common"

const DEFAULT_TRADE_AMOUNT = ton("0.05")

// Immediate trade signed by a session key: the wallet sends TRADE_AMOUNT
// (nanotons) to TRADE_TARGET right away, paid from the wallet balance.
fun main() {
    val extensionAddress = promptW5Address("EXT_ADDRESS", "Enter the installed extension address");
    val extension = TradingExtension.fromAddress(extensionAddress);
    val sessionKey = promptExternalKeyPair("SESSION_SEED");

    val target = promptW5Address("TRADE_TARGET", "Enter the transfer destination address");
    val amount = env<coins>("TRADE_AMOUNT") ?? DEFAULT_TRADE_AMOUNT;

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

    val body = createSessionTradeBody(
        sessionKey,
        extension.address,
        seqno,
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

    println("Trade sent: the wallet transferred {:ton} TON to {}", amount, target);
    println(
        "Session seqno is now {}",
        extension.extensionInfo().sessionKeys.mustGet(sessionKey.publicKey).seqno,
    );
}
