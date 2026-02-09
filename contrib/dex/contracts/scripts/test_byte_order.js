const { ethers } = require("hardhat");

async function main() {
    // Values from the failed swap
    const S_piv2 = "fbd56513c9d23b23998c7ef03f9a1e48f9ede96bdf2046e1187c7a09c2218991";
    const H_piv2 = "bebed079ad8ca9c3388a225e29695d8cc1d50f5096a53f5f788b634660d87f76";
    
    // Reverse byte order function
    function reverseBytes32(hex) {
        const clean = hex.startsWith('0x') ? hex.slice(2) : hex;
        const bytes = clean.match(/.{2}/g);
        return '0x' + bytes.reverse().join('');
    }
    
    // Convert to EVM format
    const S_evm = reverseBytes32(S_piv2);
    const H_evm = reverseBytes32(H_piv2);
    
    console.log("=== Byte Order Conversion ===");
    console.log("PIV2 Preimage (S):", "0x" + S_piv2);
    console.log("EVM Preimage (S): ", S_evm);
    console.log("PIV2 Hashlock (H):", "0x" + H_piv2);
    console.log("EVM Hashlock (H): ", H_evm);
    
    // Verify sha256 relationship
    console.log("\n=== SHA256 Verification ===");
    const computed_H = ethers.sha256(S_evm);
    console.log("sha256(S_evm):    ", computed_H);
    console.log("H_evm matches:    ", computed_H === H_evm);
    
    // If we had locked with H_evm, claim with S_evm should work
    console.log("\n=== Conclusion ===");
    if (computed_H === H_evm) {
        console.log("✓ With correct byte order:");
        console.log("  - Lock with hashlock:", H_evm);
        console.log("  - Claim with preimage:", S_evm);
        console.log("  - sha256 verification will PASS");
    } else {
        console.log("✗ Something is still wrong");
    }
}

main().catch(console.error);
