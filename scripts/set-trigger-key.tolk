import "@acton/env"
import "@acton/io"
import "@acton/emulation/scripts"
import "@wrappers/TradingExtension.gen"
import "@wrappers/utils"
import "utils/common"

fun main() {
    val deployer = promptW5Wallet("W5_DEPLOYER", "Select Wallet V5 (owner)");
    val extensionAddress = promptW5Address("EXT_ADDRESS", "Enter the installed extension address");
    val extension = TradingExtension.fromAddress(extensionAddress);

    // TRIGGER_PUBKEY=0 clears the trigger key
    val pubkey = env<int>("TRIGGER_PUBKEY") ?? promptExternalKeyPair("TRIGGER_SEED").publicKey;

    val ownerSeqno = extension.extensionInfo().ownerSeqno;
    val body = createSetTriggerKeyBody(deployer.toKeyPair(), extension.address, ownerSeqno, pubkey);
    if (!sendExtensionExternal(extension, body)) {
        return;
    }

    if (pubkey == 0) {
        println("Trigger key cleared");
    } else {
        println("Trigger key set to 0x{:x}", pubkey);
    }
    println("On-chain trigger key: 0x{:x}", extension.extensionInfo().triggerKey);
}
