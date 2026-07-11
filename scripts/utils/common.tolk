import "@acton/crypto"
import "@acton/env"
import "@acton/io"
import "@acton/prompts"
import "@acton/emulation/network"
import "@acton/emulation/scripts"
import "@wrappers/TradingExtension.gen"

fun promptW5Wallet(envName: string, message: string): ActonWallet {
    return scripts.wallet(env<string>(envName) ?? promptWallet(message));
}

fun promptW5Address(envName: string, message: string): address {
    return env<address>(envName) ?? promptAddress(message);
}

/// Ed25519 keypair for session/trigger keys. Deterministic when `<NAME>` holds a
/// hex (0x...) or decimal uint256 seed; otherwise generates a fresh keypair and
/// prints the seed so the operator can persist it.
fun promptExternalKeyPair(seedEnvName: string): KeyPair {
    val seed = env<int>(seedEnvName);
    if (seed != null) {
        return crypto.seedToKeyPair(seed);
    }
    val keyPair = crypto.generateKeyPair();
    println("{} not set — generated a fresh keypair:", seedEnvName);
    println("  seed:   0x{:x}  (save this to reuse the key)", keyPair.privateKey);
    println("  pubkey: 0x{:x}", keyPair.publicKey);
    return keyPair;
}

/// Broadcasts an already-built, owner-signed external body to the extension and
/// waits for the resulting transaction. The owner key is the wallet key, so the
/// signature — not a wallet round-trip — is what authorizes management ops.
fun sendExtensionExternal(extension: TradingExtension, body: cell): bool {
    val extResult = extension.sendAnyExternal(body);
    if (!extResult.isAccepted()) {
        println("External message was not accepted");
        return false;
    }
    if (extResult.waitForFirstTransaction() == null) {
        println("External message did not produce a transaction");
        return false;
    }
    return true;
}
