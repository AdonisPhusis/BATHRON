const { ethers } = require("hardhat");

async function main() {
    const HTLC_ADDRESS = "0x3F1843Bc98C526542d6112448842718adc13fA5F";
    
    // The hashlock as stored on Polygon
    const H_stored = "0xbebed079ad8ca9c3388a225e29695d8cc1d50f5096a53f5f788b634660d87f76";
    
    // BATHRON display format
    const S_display = "0xfbd56513c9d23b23998c7ef03f9a1e48f9ede96bdf2046e1187c7a09c2218991";
    
    // BATHRON internal (reversed)
    const S_internal = "0x918921c2097a7c18e14620df6be9edf9481e9a3ff07e8c99233bd2c91365d5fb";
    
    console.log("=== Testing preimages ===");
    console.log("Hashlock stored:", H_stored);
    console.log();
    
    // Compute sha256 in Solidity style
    const hash_display = ethers.sha256(S_display);
    console.log("sha256(S_display):", hash_display);
    console.log("Match:", hash_display === H_stored);
    
    const hash_internal = ethers.sha256(S_internal);
    console.log("sha256(S_internal):", hash_internal);
    console.log("Match:", hash_internal === H_stored);
    
    // What if we need to reverse the output?
    console.log("\n=== Byte order analysis ===");
    // H_stored reversed
    const H_reversed = "0x" + H_stored.slice(2).match(/.{2}/g).reverse().join("");
    console.log("H_stored reversed:", H_reversed);
    console.log("sha256(S_internal) == H_reversed:", hash_internal === H_reversed);
    
    // Try claim simulation
    console.log("\n=== Simulation ===");
    const htlc = await ethers.getContractAt("BATHRON_HTLC", HTLC_ADDRESS);
    
    try {
        // Simulate with S_display
        await htlc.claim.staticCall(H_stored, S_display);
        console.log("S_display: SUCCESS");
    } catch(e) {
        console.log("S_display: FAILED -", e.message.slice(0, 80));
    }
    
    try {
        // Simulate with S_internal
        await htlc.claim.staticCall(H_stored, S_internal);
        console.log("S_internal: SUCCESS");
    } catch(e) {
        console.log("S_internal: FAILED -", e.message.slice(0, 80));
    }
}

main().catch(console.error);
