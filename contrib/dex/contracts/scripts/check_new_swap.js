const { ethers } = require("hardhat");

async function main() {
    const HTLC = "0x3F1843Bc98C526542d6112448842718adc13fA5F";
    
    // Hashlock EVM (reversed from PIV2)
    const H_evm = "0x19b0345015db86ca068984e1ff73632755b20a87f89a979fa50f924d42892269";
    
    const htlc = await ethers.getContractAt("PIV2_HTLC", HTLC);
    const swap = await htlc.swaps(H_evm);
    
    console.log("=== SWAP ON POLYGON ===");
    console.log("SwapId:", H_evm);
    console.log("LP:", swap.lp);
    console.log("Taker:", swap.taker);
    console.log("Amount:", swap.amount.toString(), "(0.1 USDC = 100000)");
    console.log("Hashlock:", swap.hashlock);
    console.log("Claimed:", swap.claimed);
    console.log("Refunded:", swap.refunded);
    
    if (swap.lp !== "0x0000000000000000000000000000000000000000") {
        console.log("\n✓ Swap exists and ready for claim!");
    }
}
main().catch(console.error);
