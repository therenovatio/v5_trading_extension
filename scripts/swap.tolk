import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@wrappers/TradingExtension.gen"
import "@wrappers/utils"
import "utils/common"

// Executes one pre-built DEX transaction (e.g. a DeDust swap) through a session key:
// the session key signs a trade whose single out-action makes the W5 wallet send
// SWAP_AMOUNT to SWAP_DEST with the aggregator SWAP_PAYLOAD attached. The wallet pays
// from its own balance; the swapped tokens land in the wallet.
//
// SWAP_DEST / SWAP_AMOUNT / SWAP_PAYLOAD come from a DeDust /router/swap transaction
// (address / amount / payload). SWAP_PAYLOAD is the base64 or hex BoC of that payload.
fun main() {
    val extensionAddress = promptW5Address("EXT_ADDRESS", "Enter the installed extension address");
    val extension = TradingExtension.fromAddress(extensionAddress);
    val sessionKey = promptExternalKeyPair("SESSION_SEED");

    val dest = promptW5Address("SWAP_DEST", "Enter the swap destination (DEX vault) address");
    val amount = env<coins>("SWAP_AMOUNT");
    if (amount == null) {
        println("SWAP_AMOUNT (nanotons) is required");
        return;
    }
    val payload = env<cell>("SWAP_PAYLOAD");
    if (payload == null) {
        println("SWAP_PAYLOAD (base64/hex BoC) is required or failed to decode");
        return;
    }

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

    val outActions = buildOutActionsCell(
        [
            sendMsgActionWithBody(
                dest,
                amount,
                payload,
                SEND_MODE_PAY_FEES_SEPARATELY | SEND_MODE_IGNORE_ERRORS,
            ),
        ],
    );
    val body = createSessionTradeBody(sessionKey, extension.address, seqno, outActions);

    val extResult = extension.sendAnyExternal(body);
    if (!extResult.isAccepted()) {
        println("External message was not accepted");
        return;
    }
    if (extResult.waitForFirstTransaction() == null) {
        println("External message did not produce a transaction");
        return;
    }

    println("Swap submitted: wallet sent {:ton} TON to {} with the DEX payload", amount, dest);
    println(
        "Session seqno is now {}",
        extension.extensionInfo().sessionKeys.mustGet(sessionKey.publicKey).seqno,
    );
}
