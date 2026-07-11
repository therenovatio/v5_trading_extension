import "@acton/env"
import "@acton/io"
import "@acton/emulation/scripts"
import "@wrappers/TradingExtension.gen"
import "@wrappers/utils"
import "utils/common"

const DEFAULT_SESSION_TTL = 86400

fun main() {
    val deployer = promptW5Wallet("W5_DEPLOYER", "Select Wallet V5 (owner)");
    val extensionAddress = promptW5Address("EXT_ADDRESS", "Enter the installed extension address");
    val extension = TradingExtension.fromAddress(extensionAddress);

    val pubkey = env<int>("SESSION_PUBKEY") ?? promptExternalKeyPair("SESSION_SEED").publicKey;
    val ttl = env<int>("SESSION_VALID_SECS") ?? DEFAULT_SESSION_TTL;
    val validUntil = blockchain.now() + ttl;

    val ownerSeqno = extension.extensionInfo().ownerSeqno;
    val body = createAddSessionKeyBody(
        deployer.toKeyPair(),
        extension.address,
        ownerSeqno,
        pubkey,
        validUntil,
    );
    if (!sendExtensionExternal(extension, body)) {
        return;
    }

    println("Session key 0x{:x} added, valid until {}", pubkey, validUntil);
    println("Registered: {}", extension.extensionInfo().sessionKeys.exists(pubkey));
}
