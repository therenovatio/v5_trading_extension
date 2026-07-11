import "@acton/env"
import "@acton/io"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@wrappers/TradingExtension.gen"
import "utils/common"

fun main() {
    val deployer = promptW5Wallet("W5_DEPLOYER", "Select Wallet V5 Deployer");

    // The owner key is the wallet's own Ed25519 key; management ops are signed with it.
    // Available from the wallet registry only under --net; in emulation, pass OWNER_PUBKEY
    // (or accept the 0 placeholder — the emulation deploy is only a smoke test).
    val ownerKey = env<int>("OWNER_PUBKEY") ?? (net.isBroadcasting() ? deployer.publicKey() : 0);

    val extension = TradingExtension.fromStorage({
        walletAddress: deployer.address,
        ownerKey,
        ownerSeqno: 0,
        triggerKey: 0,
        openOrderCount: 0,
        orderNonce: 0,
        sessionKeys: [],
        orders: [],
    });

    val res = extension.deploy(deployer.address, { value: ton("0.5"), bounce: false });

    if (res.waitForFirstTransaction() == null) {
        return;
    }

    println("Deployed trading extension to {}", extension.address);
    println("Configured wallet address {}", extension.extensionInfo().walletAddress);
    println("Owner key 0x{:x}", extension.extensionInfo().ownerKey);
}
