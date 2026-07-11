import "@acton/env"
import "@acton/io"
import "@wrappers/TradingExtension.gen"
import "utils/common"

const DEFAULT_REFRESH_WINDOW = 21600 // warn to refresh when < 6h remain

// Read-only: reports whether a session key is registered, and how long until it
// expires, so a trading terminal can remind the owner to refresh before it lapses.
fun main() {
    val extensionAddress = promptW5Address("EXT_ADDRESS", "Enter the installed extension address");
    val extension = TradingExtension.fromAddress(extensionAddress);

    val pubkey = env<int>("SESSION_PUBKEY") ?? promptExternalKeyPair("SESSION_SEED").publicKey;
    val refreshWindow = env<int>("REFRESH_WINDOW_SECS") ?? DEFAULT_REFRESH_WINDOW;

    val status = extension.sessionKeyStatus(pubkey);
    println("Session key: 0x{:x}", pubkey);

    if (!status.found) {
        println("Status: NOT REGISTERED (never added, or revoked) — owner must re-register it");
        return;
    }

    val now = blockchain.now();
    println("Registered: yes  (seqno {})", status.seqno);
    println("Valid until: {}", status.validUntil);

    if (status.validUntil <= now) {
        println("Status: EXPIRED — owner must refresh (re-add) the key; seqno is preserved");
    } else {
        val remaining = status.validUntil - now;
        if (remaining < refreshWindow) {
            println(
                "Status: EXPIRING SOON — {} seconds left; prompt the owner to refresh",
                remaining,
            );
        } else {
            println("Status: ACTIVE — {} seconds left", remaining);
        }
    }
}
