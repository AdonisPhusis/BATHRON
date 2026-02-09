const { ethers } = require("hardhat");

async function main() {
    const HTLC = "0x3F1843Bc98C526542d6112448842718adc13fA5F";
    
    // EVM format (reversed from BATHRON)
    const swapId = "0x19b0345015db86ca068984e1ff73632755b20a87f89a979fa50f924d42892269";
    const preimage = "0xa97290f324814a7fbc06d3230ac3ecff6c4eb3f00b1ab81a1f17012ea25f3343";
    
    console.log("=== CLAIM USDC ===");
    console.log("SwapId:", swapId);
    console.log("Preimage:", preimage);
    
    // Verify sha256 first
    const computed = ethers.sha256(preimage);
    console.log("sha256(preimage):", computed);
    console.log("Match swapId:", computed === swapId);
    
    if (computed !== swapId) {
        console.log("ERROR: Hash mismatch!");
        return;
    }
    
    const htlc = await ethers.getContractAt("BATHRON_HTLC", HTLC);
    const [signer] = await ethers.getSigners();
    
    console.log("\nClaiming from:", signer.address);
    
    // Claim
    const tx = await htlc.claim(swapId, preimage);
    console.log("TX sent:", tx.hash);
    
    const receipt = await tx.wait();
    console.log("TX confirmed! Block:", receipt.blockNumber);
    console.log("\n✓ USDC claimed successfully!");
    console.log("LP received 0.1 USDC at 0x73748C0CDf44c360De6F4aC66E488384F4c8664B");
}
main().catch(console.error);
