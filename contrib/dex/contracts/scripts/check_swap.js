const { ethers } = require("hardhat");

async function main() {
    const HTLC_ADDRESS = "0x3F1843Bc98C526542d6112448842718adc13fA5F";
    const SWAP_ID = "0xbebed079ad8ca9c3388a225e29695d8cc1d50f5096a53f5f788b634660d87f76";
    
    const htlc = await ethers.getContractAt("PIV2_HTLC", HTLC_ADDRESS);
    
    const swap = await htlc.swaps(SWAP_ID);
    console.log("Swap data for swapId:", SWAP_ID);
    console.log("  LP:", swap.lp);
    console.log("  Taker:", swap.taker);
    console.log("  Token:", swap.token);
    console.log("  Amount:", swap.amount.toString());
    console.log("  Hashlock:", swap.hashlock);
    console.log("  Timelock:", swap.timelock.toString());
    console.log("  Claimed:", swap.claimed);
    console.log("  Refunded:", swap.refunded);
    
    // Also try the reversed swapId
    const SWAP_ID_REV = "0x767fd86046638b785f3fa596500fd5c18c5d69295e228a38c3a98cad79d0bebe";
    console.log("\n--- Trying reversed swapId ---");
    const swap2 = await htlc.swaps(SWAP_ID_REV);
    console.log("Swap for reversed:", swap2.lp != "0x0000000000000000000000000000000000000000" ? "EXISTS" : "NOT FOUND");
}

main().catch(console.error);
