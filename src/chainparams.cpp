// Copyright (c) 2010 Satoshi Nakamoto
// Copyright (c) 2009-2015 The Bitcoin developers
// Copyright (c) 2014-2015 The Dash developers
// Copyright (c) 2015-2022 The PIVX Core developers
// Copyright (c) 2025 The PIVHU developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "chainparams.h"

#include "arith_uint256.h"
#include "chainparamsseeds.h"
#include "consensus/merkle.h"
#include "tinyformat.h"
#include "utilstrencodings.h"
#include "version.h"  // For TESTNET_EPOCH

#include <assert.h>

/**
 * PIVHU Genesis Mining Utility
 * Finds a valid nonce for the genesis block that meets the difficulty target.
 * Call this once to get the correct nonce, then hardcode it.
 */
static void MineGenesisBlock(CBlock& genesis, const uint256& bnGenesisTarget)
{
    arith_uint256 bnTarget;
    bnTarget.SetCompact(genesis.nBits);

    // Check if current hash already meets target
    uint256 currentHash = genesis.GetHash();
    if (UintToArith256(currentHash) <= bnTarget) {
        printf("PIVHU Genesis: Already valid!\n");
        printf("  nNonce: %u\n", genesis.nNonce);
        printf("  Hash: %s\n", currentHash.ToString().c_str());
        printf("  MerkleRoot: %s\n", genesis.hashMerkleRoot.ToString().c_str());
        return;
    }

    printf("PIVHU Genesis Mining: Searching for nonce...\n");
    printf("  Time: %u\n", genesis.nTime);
    printf("  nBits: 0x%08x\n", genesis.nBits);
    printf("  Target: %s\n", bnTarget.ToString().c_str());
    printf("  MerkleRoot: %s\n", genesis.hashMerkleRoot.ToString().c_str());

    for (genesis.nNonce = 0; genesis.nNonce < UINT32_MAX; genesis.nNonce++) {
        uint256 hash = genesis.GetHash();
        if (UintToArith256(hash) <= bnTarget) {
            printf("PIVHU Genesis Found!\n");
            printf("  nNonce: %u\n", genesis.nNonce);
            printf("  Hash: %s\n", hash.ToString().c_str());
            printf("  MerkleRoot: %s\n", genesis.hashMerkleRoot.ToString().c_str());
            break;
        }
        if ((genesis.nNonce % 100000) == 0) {
            printf("  Mining... nNonce=%u\n", genesis.nNonce);
        }
    }
}

static CBlock CreateGenesisBlock(const char* pszTimestamp, const CScript& genesisOutputScript, uint32_t nTime, uint32_t nNonce, uint32_t nBits, int32_t nVersion, const CAmount& genesisReward)
{
    CMutableTransaction txNew;
    txNew.nVersion = 1;
    txNew.vin.resize(1);
    txNew.vout.resize(1);
    txNew.vin[0].scriptSig = CScript() << 486604799 << CScriptNum(4) << std::vector<unsigned char>((const unsigned char*)pszTimestamp, (const unsigned char*)pszTimestamp + strlen(pszTimestamp));
    txNew.vout[0].nValue = genesisReward;
    txNew.vout[0].scriptPubKey = genesisOutputScript;

    CBlock genesis;
    genesis.vtx.push_back(std::make_shared<const CTransaction>(std::move(txNew)));
    genesis.hashPrevBlock.SetNull();
    genesis.nVersion = nVersion;
    genesis.nTime    = nTime;
    genesis.nBits    = nBits;
    genesis.nNonce   = nNonce;
    genesis.hashMerkleRoot = BlockMerkleRoot(genesis);
    return genesis;
}

void CChainParams::UpdateNetworkUpgradeParameters(Consensus::UpgradeIndex idx, int nActivationHeight)
{
    assert(IsRegTestNet()); // only available for regtest
    assert(idx > Consensus::BASE_NETWORK && idx < Consensus::MAX_NETWORK_UPGRADES);
    consensus.vUpgrades[idx].nActivationHeight = nActivationHeight;
}

/**
 * Build the genesis block. Note that the output of the genesis coinbase cannot
 * be spent as it did not originally exist in the database.
 *
 * CBlock(hash=00000ffd590b14, ver=1, hashPrevBlock=00000000000000, hashMerkleRoot=e0028e, nTime=1390095618, nBits=1e0ffff0, nNonce=28917698, vtx=1)
 *   CTransaction(hash=e0028e, ver=1, vin.size=1, vout.size=1, nLockTime=0)
 *     CTxIn(COutPoint(000000, -1), coinbase 04ffff001d01044c5957697265642030392f4a616e2f3230313420546865204772616e64204578706572696d656e7420476f6573204c6976653a204f76657273746f636b2e636f6d204973204e6f7720416363657074696e6720426974636f696e73)
 *     CTxOut(nValue=50.00000000, scriptPubKey=0xA9037BAC7050C479B121CF)
 *   vMerkleTree: e0028e
 */
static CBlock CreateGenesisBlock(uint32_t nTime, uint32_t nNonce, uint32_t nBits, int32_t nVersion, const CAmount& genesisReward)
{
    const char* pszTimestamp = "U.S. News & World Report Jan 28 2016 With His Absence, Trump Dominates Another Debate";
    const CScript genesisOutputScript = CScript() << ParseHex("04c10e83b2703ccf322f7dbd62dd5855ac7c10bd055814ce121ba32607d573b8810c02c0582aed05b4deb9c4b77b26d92428c61256cd42774babea0a073b2ed0c9") << OP_CHECKSIG;
    return CreateGenesisBlock(pszTimestamp, genesisOutputScript, nTime, nNonce, nBits, nVersion, genesisReward);
}

/**
 * PIVHU Genesis Block - Clean start with MN-only consensus
 *
 * MAINNET/TESTNET Distribution (99,120,000 M0 total):
 * - Swap Reserve:   98,000,000 M0 (HTLC atomic swap reserve)
 * - Dev/Test:          500,000 M0 (~0.5% development fund)
 * - Reserve:           500,000 M0 (~0.5% reserve)
 * - MN Collateral:     120,000 M0 (12 × 10,000 for initial masternodes)
 *
 * BP30 SettlementState at genesis (P1): M0_vaulted=0, M1=0
 * Block reward = 0 (supply from BTC burns only)
 */
static CBlock CreatePIVHUGenesisBlock(uint32_t nTime, uint32_t nNonce, uint32_t nBits, int32_t nVersion)
{
    const char* pszTimestamp = "PIVHU Genesis Nov 2025 - Knowledge Hedge Unit - MN Consensus - Zero Block Reward";

    CMutableTransaction txNew;
    txNew.nVersion = 1;
    txNew.vin.resize(1);
    txNew.vin[0].scriptSig = CScript() << 486604799 << CScriptNum(4) << std::vector<unsigned char>((const unsigned char*)pszTimestamp, (const unsigned char*)pszTimestamp + strlen(pszTimestamp));

    // PIVHU Genesis Distribution - 4 outputs (mainnet/testnet)
    // Note: These are placeholder addresses - replace with real addresses before mainnet launch
    // Output 0: Swap Reserve (98,000,000 PIVHU for HTLC atomic swaps)
    const CScript swapReserveScript = CScript() << ParseHex("04c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee51ae168fea63dc339a3c58419466ceae1061021a6e8c1b0ec7e3c0d4b2a9d2d3c") << OP_CHECKSIG;
    // Output 1: Dev/Test Wallet (500,000 PIVHU)
    const CScript devRewardScript = CScript() << ParseHex("04678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5f") << OP_CHECKSIG;
    // Output 2: Reserve (500,000 M0)
    const CScript reserveScript = CScript() << ParseHex("0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8") << OP_CHECKSIG;
    // Output 3: MN Collateral Pool (120,000 PIVHU = 12 × 10,000)
    const CScript mnCollateralScript = CScript() << ParseHex("04f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9388f7b0f632de8140fe337e62a37f3566500a99934c2231b6cb9fd7584b8e672") << OP_CHECKSIG;

    txNew.vout.resize(4);
    txNew.vout[0].nValue = 98000000 * COIN;    // Swap Reserve
    txNew.vout[0].scriptPubKey = swapReserveScript;
    txNew.vout[1].nValue = 500000 * COIN;      // Dev/Test
    txNew.vout[1].scriptPubKey = devRewardScript;
    txNew.vout[2].nValue = 500000 * COIN;      // Reserve
    txNew.vout[2].scriptPubKey = reserveScript;
    txNew.vout[3].nValue = 120000 * COIN;      // MN Collateral Pool
    txNew.vout[3].scriptPubKey = mnCollateralScript;

    CBlock genesis;
    genesis.vtx.push_back(std::make_shared<const CTransaction>(std::move(txNew)));
    genesis.hashPrevBlock.SetNull();
    genesis.nVersion = nVersion;
    genesis.nTime    = nTime;
    genesis.nBits    = nBits;
    genesis.nNonce   = nNonce;
    genesis.hashMerkleRoot = BlockMerkleRoot(genesis);
    return genesis;
}

/**
 * BATHRON Testnet Genesis Block - Minimal (snapshot simulation)
 *
 * Genesis coinbase is NOT spendable (Bitcoin design).
 * Initial supply distributed at Block 1 via premine (simulates snapshot import).
 *
 * Block 0 (Genesis):
 *   - Coinbase: 0 BATHRON (symbolic, not spendable)
 *   - 3 MNs injected virtually into DMN list
 *
 * Block 1 (Premine):
 *   - MN1 Collateral: 10,000 BATHRON (SPENDABLE)
 *   - MN2 Collateral: 10,000 BATHRON (SPENDABLE)
 *   - MN3 Collateral: 10,000 BATHRON (SPENDABLE)
 *   - Dev Wallet: 50,000,000 BATHRON (SPENDABLE)
 *   - Faucet: 50,000,000 BATHRON (SPENDABLE)
 *   Total: 100,030,000 BATHRON
 */
static CBlock CreatePIVHUTestnetGenesisBlock(uint32_t nTime, uint32_t nNonce, uint32_t nBits, int32_t nVersion)
{
    const char* pszTimestamp = "BATHRON Testnet Dec 2025 - Snapshot Genesis v4 - DMM from Block 1";

    CMutableTransaction txNew;
    txNew.nVersion = 1;
    txNew.vin.resize(1);
    txNew.vin[0].scriptSig = CScript() << 486604799 << CScriptNum(4) << std::vector<unsigned char>((const unsigned char*)pszTimestamp, (const unsigned char*)pszTimestamp + strlen(pszTimestamp));

    // ═══════════════════════════════════════════════════════════════════════════
    // BATHRON Testnet Genesis - MINIMAL coinbase (0 BATHRON)
    // ═══════════════════════════════════════════════════════════════════════════
    // Genesis coinbase is NOT spendable by Bitcoin design.
    // All real supply comes from Block 1 premine (snapshot simulation).
    // This output exists only because a coinbase tx must have at least 1 output.
    // ═══════════════════════════════════════════════════════════════════════════
    txNew.vout.resize(1);
    txNew.vout[0].nValue = 0;  // 0 BATHRON - symbolic only
    txNew.vout[0].scriptPubKey = CScript() << OP_DUP << OP_HASH160 << ParseHex("0000000000000000000000000000000000000000") << OP_EQUALVERIFY << OP_CHECKSIG;

    CBlock genesis;
    genesis.vtx.push_back(std::make_shared<const CTransaction>(std::move(txNew)));
    genesis.hashPrevBlock.SetNull();
    genesis.nVersion = nVersion;
    genesis.nTime    = nTime;
    genesis.nBits    = nBits;
    genesis.nNonce   = nNonce;
    genesis.hashMerkleRoot = BlockMerkleRoot(genesis);
    return genesis;
}

/**
 * PIVHU Regtest Genesis Block - Simplified for testing
 *
 * REGTEST Distribution (99,120,000 M0 total):
 * - Test Wallet:    50,000,000 M0 (~50% for easy testing)
 * - Swap Reserve:   48,500,000 M0 (remaining swap reserve)
 * - Reserve:           500,000 M0 (reserve)
 * - MN Collateral:     120,000 M0 (12 × 10,000 for masternodes)
 *
 * Regtest gives majority to test wallet for convenient testing of BP30 settlement operations.
 */
static CBlock CreatePIVHURegtestGenesisBlock(uint32_t nTime, uint32_t nNonce, uint32_t nBits, int32_t nVersion)
{
    const char* pszTimestamp = "PIVHU Regtest Dec 2025 - Knowledge Hedge Unit - Test Genesis v2";

    CMutableTransaction txNew;
    txNew.nVersion = 1;
    txNew.vin.resize(1);
    txNew.vin[0].scriptSig = CScript() << 486604799 << CScriptNum(4) << std::vector<unsigned char>((const unsigned char*)pszTimestamp, (const unsigned char*)pszTimestamp + strlen(pszTimestamp));

    // ═══════════════════════════════════════════════════════════════════════════
    // PIVHU Regtest Distribution - P2PKH outputs with KNOWN private keys
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Generated from regtest wallet - NEVER use on mainnet!
    //
    // Output 0: Test Wallet (50M HU)
    //   Address: y65ffDxjd8WVQn4J4ByKhSDWwVMs2r4k7d
    //   WIF:     cMpec6ZShrJvVMfehkdqVbkK9sHQCsqeBpyd7q5c682KxpbNT2aR
    //
    // Output 1: MN1 Collateral (100 HU)
    //   Address: y48kso2j49HW3mZtNasQxumSVpWzN6H16H
    //   WIF:     cRtHEkQ53gfYg3NWbpb8nCLPxebyRVEEfRpcWJVyLMhhp1wLmhdB
    //
    // Output 2: MN2 Collateral (100 HU)
    //   Address: y9Drs8V4updrVkuEAP3HyZfJukrZh3LBNm
    //   WIF:     cS3s7E4zVgtvn5BBz1ZcDgdfbs2t1qcNB8tQjffq64xo2aHc7XSq
    //
    // Output 3: MN3 Collateral (100 HU)
    //   Address: yEvakh8hWeVvfHY4kXBxowQ1gus2Q1imTP
    //   WIF:     cQX5FKoWNny66nYJEwwCwXVvhzn7Mm6C6u2zcPrhDFZ6tgPMiPni
    //
    // Output 4: MN Ops Fund (119,700 HU)
    //   Address: y6wgMBkg9BXfdMAH7Cf1quRZjJz98qaPAq
    //   WIF:     cPP8PfQgEaStUECCpKFzpZt9hFis8tj6E2vtqr3gweLyZkuwuvvY
    //
    // Output 5: Swap Reserve (48.5M HU)
    //   Address: y4wrFnnsRTkDhxBp61gDnjZ9Fg8yt7x34D
    //   WIF:     cNYJdV6Muuu1oVRP2fsCHYeTx3pkaq7itEV45mK36gTziSLQ4Qox
    //
    // Output 6: Reserve (500K M0)
    //   Address: yBNsxgEURuLLSYTjgT5fmUwBPK77s8a5fZ
    //   WIF:     cUhVQbjcbttjN8yLVyY5maqweRZsFSRBsrbo3335AiPWscYAVa66
    //
    // ═══════════════════════════════════════════════════════════════════════════

    txNew.vout.resize(7);

    // Output 0: Test Wallet (50M)
    txNew.vout[0].nValue = 50000000 * COIN;
    txNew.vout[0].scriptPubKey = CScript() << OP_DUP << OP_HASH160 << ParseHex("63d31c01f548cc5d314cf692f727157475b9d4a9") << OP_EQUALVERIFY << OP_CHECKSIG;

    // Output 1: MN1 Collateral (100)
    txNew.vout[1].nValue = 100 * COIN;
    txNew.vout[1].scriptPubKey = CScript() << OP_DUP << OP_HASH160 << ParseHex("4e7875de8946177c9fd5fc55fcbc54a34c8a4ab9") << OP_EQUALVERIFY << OP_CHECKSIG;

    // Output 2: MN2 Collateral (100)
    txNew.vout[2].nValue = 100 * COIN;
    txNew.vout[2].scriptPubKey = CScript() << OP_DUP << OP_HASH160 << ParseHex("86482b0b101caf70223a43ca2a68f91aaf02786d") << OP_EQUALVERIFY << OP_CHECKSIG;

    // Output 3: MN3 Collateral (100)
    txNew.vout[3].nValue = 100 * COIN;
    txNew.vout[3].scriptPubKey = CScript() << OP_DUP << OP_HASH160 << ParseHex("c4d467187c9287c486e2954e72275cd767bf361a") << OP_EQUALVERIFY << OP_CHECKSIG;

    // Output 4: MN Ops Fund (119,700)
    txNew.vout[4].nValue = 119700 * COIN;
    txNew.vout[4].scriptPubKey = CScript() << OP_DUP << OP_HASH160 << ParseHex("6d487b8e666a54a23bbdf5d5fcb6d55c677ee82a") << OP_EQUALVERIFY << OP_CHECKSIG;

    // Output 5: Swap Reserve (48.5M)
    txNew.vout[5].nValue = 48500000 * COIN;
    txNew.vout[5].scriptPubKey = CScript() << OP_DUP << OP_HASH160 << ParseHex("5760804121da48fd43d266282cbddc8f0e7962af") << OP_EQUALVERIFY << OP_CHECKSIG;

    // Output 6: Reserve (500K M0)
    txNew.vout[6].nValue = 500000 * COIN;
    txNew.vout[6].scriptPubKey = CScript() << OP_DUP << OP_HASH160 << ParseHex("9ded13f5233a7fede9f7f70de3a9739d1405d001") << OP_EQUALVERIFY << OP_CHECKSIG;

    CBlock genesis;
    genesis.vtx.push_back(std::make_shared<const CTransaction>(std::move(txNew)));
    genesis.hashPrevBlock.SetNull();
    genesis.nVersion = nVersion;
    genesis.nTime    = nTime;
    genesis.nBits    = nBits;
    genesis.nNonce   = nNonce;
    genesis.hashMerkleRoot = BlockMerkleRoot(genesis);
    return genesis;
}

/**
 * Main network
 */
/**
 * What makes a good checkpoint block?
 * + Is surrounded by blocks with reasonable timestamps
 *   (no blocks before with a timestamp after, none after with
 *    timestamp before)
 * + Contains no strange transactions
 */
// PIVHU will have its own genesis and checkpoint history
static MapCheckpoints mapCheckpoints = {};

static const CCheckpointData data = {
    &mapCheckpoints,
    0,    // * UNIX timestamp of last checkpoint block
    0,    // * total number of transactions between genesis and last checkpoint
    0     // * estimated number of transactions per day after checkpoint
};

static MapCheckpoints mapCheckpointsTestnet = {};

static const CCheckpointData dataTestnet = {
    &mapCheckpointsTestnet,
    0,
    0,
    0};

static MapCheckpoints mapCheckpointsRegtest = {};
static const CCheckpointData dataRegtest = {
    &mapCheckpointsRegtest,
    0,
    0,
    0};

class CMainParams : public CChainParams
{
public:
    CMainParams()
    {
        strNetworkID = "hu-main";

        // PIVHU Genesis Block
        // Timestamp: Nov 30, 2025 00:00:00 UTC (1732924800)
        // PIVHU uses higher difficulty target initially for MN-only consensus
        // nNonce and hashes will be mined - use placeholders for now
        genesis = CreatePIVHUGenesisBlock(1732924800, 0, 0x1e0ffff0, 1);
        consensus.hashGenesisBlock = genesis.GetHash();

        // Genesis hashes - run with -printgenesis to mine
        // TODO: Mine and replace these placeholder values
        // assert(consensus.hashGenesisBlock == uint256S("0x..."));
        // assert(genesis.hashMerkleRoot == uint256S("0x..."));

        // ═══════════════════════════════════════════════════════════════════════
        // HU Core Economic Parameters - MAINNET
        // ═══════════════════════════════════════════════════════════════════════
        consensus.nMaxMoneyOut = 99120000 * COIN;   // HU: 99.12M total supply at genesis
        consensus.nMNCollateralAmt = 1000000; // 1,000,000 sats = 0.01 BTC (M0 collateral)
        consensus.nMNBlockReward = 0;               // HU: Block reward = 0 (BTC burn-to-mint economy)
        consensus.nNewMNBlockReward = 0;            // HU: Block reward = 0 (BTC burn-to-mint economy)
        consensus.nTargetTimespan = 40 * 60;
        consensus.nTargetTimespanV2 = 30 * 60;
        consensus.nTargetSpacing = 1 * 60;          // HU: 60 second blocks
        consensus.nTimeSlotLength = 15;

        // ═══════════════════════════════════════════════════════════════════════
        // BP30 Timing Parameters - MAINNET (production values)
        // ═══════════════════════════════════════════════════════════════════════

        // Masternode collateral maturity: 1 day (prevents quorum manipulation)
        consensus.nMasternodeCollateralMinConf = 1440;  // 1 day × 1440 blocks/day

        // Masternode vote maturity: 30 days (prevents "pump & vote" attacks)
        consensus.nMasternodeVoteMaturityBlocks = 43200;  // 30 days × 1440 blocks/day

        // Blocks per day (for rate limiting, diagnostics)
        consensus.nBlocksPerDay = 1440;             // 1440 blocks/day @ 60s/block

        // ═══════════════════════════════════════════════════════════════════════
        // HU DMM + Finality Parameters - MAINNET
        // Quorum: 12 MNs ("apostles"), 8/12 threshold, rotate every 12 blocks
        // ═══════════════════════════════════════════════════════════════════════
        consensus.nHuBlockTimeSeconds = 60;         // 60 second target block time
        consensus.nHuQuorumSize = 12;               // 12 masternodes per quorum
        consensus.nHuQuorumThreshold = 8;           // 8/12 signatures for finality
        consensus.nHuQuorumRotationBlocks = 12;     // New quorum every 12 blocks
        consensus.nHuLeaderTimeoutSeconds = 45;     // DMM leader timeout (fallback after 45s)
        consensus.nHuFallbackRecoverySeconds = 15;  // Recovery window for fallback MNs
        consensus.nDMMBootstrapHeight = 10;         // Bootstrap phase (no slot calculation for cold start)
        consensus.nHuMaxReorgDepth = 0;             // No artificial limit - reorg blocked by actual HU finality only
        consensus.nStaleChainTimeout = 3600;        // SECURITY: 1 hour for mainnet cold start recovery

        // BATHRON: spork system removed - see 03-SPORKS-MODERNIZATION blueprint

        // ═══════════════════════════════════════════════════════════════════════
        // BTC SPV & Burn Parameters - MAINNET
        // All burns (including pre-launch) detected by burn_claim_daemon
        // ═══════════════════════════════════════════════════════════════════════
        consensus.burnPrefix = "BATHRON1";           // OP_RETURN prefix for burn detection
        consensus.burnScanVoutMin = 0;               // Scan outputs [0..2] for OP_RETURN
        consensus.burnScanVoutMax = 2;
        consensus.burnScanBtcHeightStart = 840000;   // MAINNET: Start at halving block (2024)
        consensus.burnScanBtcHeightEnd = 840000;     // MAINNET: No genesis burns range

        // ALL upgrades active from GENESIS (no height-based activation)
        // This is the PIVHU way: clean start, all features active from block 0
        consensus.vUpgrades[Consensus::BASE_NETWORK].nActivationHeight =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_TESTDUMMY].nActivationHeight =
                Consensus::NetworkUpgrade::NO_ACTIVATION_HEIGHT;
        consensus.vUpgrades[Consensus::UPGRADE_BIP65].nActivationHeight         =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V3_4].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V4_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;  // Sapling version
        consensus.vUpgrades[Consensus::UPGRADE_V5_2].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_3].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_5].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_6].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V6_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;  // BP30 settlement active from genesis
        consensus.vUpgrades[Consensus::UPGRADE_V7_0].nActivationHeight          =
                Consensus::NetworkUpgrade::NO_ACTIVATION_HEIGHT;  // CTV-lite: not active on mainnet yet


        /**
         * The message start string is designed to be unlikely to occur in normal data.
         * The characters are rarely used upper ASCII, not valid as UTF-8, and produce
         * a large 4-byte int at any alignment.
         */
        pchMessageStart[0] = 0x90;
        pchMessageStart[1] = 0xc4;
        pchMessageStart[2] = 0xfd;
        pchMessageStart[3] = 0xe9;
        nDefaultPort = 51472;

        // vSeeds.emplace_back("pivx.seed.fuzzbawls.pw", true);
        // vSeeds.emplace_back("pivx.seed2.fuzzbawls.pw", true);
        // vSeeds.emplace_back("dnsseed.liquid369.wtf", true);

        base58Prefixes[PUBKEY_ADDRESS] = std::vector<unsigned char>(1, 30);
        base58Prefixes[SCRIPT_ADDRESS] = std::vector<unsigned char>(1, 13);
        base58Prefixes[EXCHANGE_ADDRESS] = {0x01, 0xb9, 0xa2};   // starts with EXM
        base58Prefixes[SECRET_KEY] = std::vector<unsigned char>(1, 212);
        base58Prefixes[EXT_PUBLIC_KEY] = {0x02, 0x2D, 0x25, 0x33};
        base58Prefixes[EXT_SECRET_KEY] = {0x02, 0x21, 0x31, 0x2B};
        // BIP44 coin type is from https://github.com/satoshilabs/slips/blob/master/slip-0044.md
        base58Prefixes[EXT_COIN_TYPE] = {0x80, 0x00, 0x00, 0x77};

        vFixedSeeds = std::vector<uint8_t>(std::begin(chainparams_seed_main), std::end(chainparams_seed_main));

        // Reject non-standard transactions by default
        fRequireStandard = true;

        // Sapling
        bech32HRPs[SAPLING_PAYMENT_ADDRESS]      = "ps";
        bech32HRPs[SAPLING_FULL_VIEWING_KEY]     = "pviews";
        bech32HRPs[SAPLING_INCOMING_VIEWING_KEY] = "pivks";
        bech32HRPs[SAPLING_EXTENDED_SPEND_KEY]   = "p-secret-spending-key-main";
        bech32HRPs[SAPLING_EXTENDED_FVK]         = "pxviews";

        // Tier two
        nFulfilledRequestExpireTime = 60 * 60; // fulfilled requests expire in 1 hour
    }

    const CCheckpointData& Checkpoints() const
    {
        return data;
    }

};

/**
 * PIVHU Testnet - for testing MN-only consensus and BP30 settlement features
 */
class CTestNetParams : public CChainParams
{
public:
    CTestNetParams()
    {
        strNetworkID = "bathron-testnet";

        // ═══════════════════════════════════════════════════════════════════════
        // BATHRON Testnet Genesis v4 - Minimal (snapshot simulation)
        // ═══════════════════════════════════════════════════════════════════════
        // Genesis coinbase: 0 BATHRON (not spendable by Bitcoin design)
        // Block 1 premine: 100,030,000 BATHRON (simulates snapshot import)
        //   - MN1/2/3 Collateral: 3 × 10,000 BATHRON
        //   - Dev Wallet: 50,000,000 BATHRON
        //   - Faucet: 50,000,000 BATHRON
        // 3 MNs injected virtually into DMN list at genesis
        // ═══════════════════════════════════════════════════════════════════════
        // Note: nNonce needs to be mined - will be done at first launch
        genesis = CreatePIVHUTestnetGenesisBlock(1733443200, 0, 0x1e0ffff0, 1);  // Dec 6, 2025
        consensus.hashGenesisBlock = genesis.GetHash();

        // Genesis will be mined at first launch (MineGenesisBlock)
        // Temporarily disable hash assertions until genesis is mined
        // TODO: Uncomment after mining genesis with correct nNonce
        // assert(consensus.hashGenesisBlock == uint256S("0x..."));
        // assert(genesis.hashMerkleRoot == uint256S("0x..."));

        // ═══════════════════════════════════════════════════════════════════════
        // HU Core Economic Parameters - TESTNET
        // ═══════════════════════════════════════════════════════════════════════
        consensus.nMaxMoneyOut = 100030000 * COIN;  // HU: 100.03M (3×10k MN + 50M dev + 50M faucet)
        consensus.nMNCollateralAmt = 1000000; // 1,000,000 sats = 0.01 BTC (M0 collateral)
        consensus.nMNBlockReward = 0;               // HU: Block reward = 0 (BTC burn-to-mint economy)
        consensus.nNewMNBlockReward = 0;            // HU: Block reward = 0 (BTC burn-to-mint economy)
        consensus.nTargetTimespan = 40 * 60;
        consensus.nTargetTimespanV2 = 30 * 60;
        consensus.nTargetSpacing = 1 * 60;          // HU: 60 second blocks
        consensus.nTimeSlotLength = 15;

        // ═══════════════════════════════════════════════════════════════════════
        // BP30 Timing Parameters - TESTNET (accelerated for testing)
        // ═══════════════════════════════════════════════════════════════════════

        // Masternode collateral maturity: 1 hour (faster testing)
        consensus.nMasternodeCollateralMinConf = 60;  // 1 hour × 1 block/min

        // Masternode vote maturity: 1 hour (prevents "pump & vote" attacks)
        consensus.nMasternodeVoteMaturityBlocks = 60;  // 1 hour × 1 block/min

        // Blocks per day (for rate limiting, diagnostics)
        consensus.nBlocksPerDay = 360;              // 6 hours update cycle for testnet

        // ═══════════════════════════════════════════════════════════════════════
        // HU DMM + Finality Parameters - TESTNET
        // Smaller quorum (3 MNs), faster rotation for testing
        // ═══════════════════════════════════════════════════════════════════════
        consensus.nHuBlockTimeSeconds = 60;         // 60 second target block time
        consensus.nHuQuorumSize = 3;                // 3 masternodes per quorum (all MNs in small testnet)
        consensus.nHuQuorumThreshold = 2;           // 2/3 MN signatures for finality (stake-based)
        consensus.nHuQuorumRotationBlocks = 3;      // Fast rotation (every 3 blocks)
        consensus.nHuLeaderTimeoutSeconds = 45;     // Leader timeout (was 30, increased for reliability)
        consensus.nHuFallbackRecoverySeconds = 15;  // Fallback window (was 10)
        consensus.nDMMBootstrapHeight = 250;         // Bootstrap: header catch-up + burn claims + 20 K_FINALITY + mint + MN reg + margin
        consensus.nHuMaxReorgDepth = 0;             // No artificial limit - reorg blocked by actual HU finality only
        consensus.nStaleChainTimeout = 600;         // 10 minutes for testnet cold start recovery

        // BATHRON: spork system removed - see 03-SPORKS-MODERNIZATION blueprint

        // ═══════════════════════════════════════════════════════════════════════
        // BTC SPV & Burn Parameters - TESTNET
        // All burns (including pre-launch) detected by burn_claim_daemon
        // ═══════════════════════════════════════════════════════════════════════
        consensus.burnPrefix = "BATHRON1";           // OP_RETURN prefix for burn detection
        consensus.burnScanVoutMin = 0;               // Scan outputs [0..2] for OP_RETURN
        consensus.burnScanVoutMax = 2;
        consensus.burnScanBtcHeightStart = 200000;   // TESTNET/Signet: Start from checkpoint
        consensus.burnScanBtcHeightEnd = 300000;     // TESTNET/Signet: ~6 months after checkpoint

        // ALL upgrades active from GENESIS (no height-based activation)
        // This is the BATHRON way: clean start, all features active from block 0
        consensus.vUpgrades[Consensus::BASE_NETWORK].nActivationHeight =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_TESTDUMMY].nActivationHeight =
                Consensus::NetworkUpgrade::NO_ACTIVATION_HEIGHT;
        consensus.vUpgrades[Consensus::UPGRADE_BIP65].nActivationHeight         =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V3_4].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V4_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;  // Sapling version
        consensus.vUpgrades[Consensus::UPGRADE_V5_2].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_3].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_5].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_6].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V6_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;  // BP30 settlement active from genesis
        consensus.vUpgrades[Consensus::UPGRADE_V7_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;  // CTV-lite: active on testnet

        // ═══════════════════════════════════════════════════════════════════════
        // BATHRON Testnet - No Genesis MNs (Clean Design)
        // ═══════════════════════════════════════════════════════════════════════
        // Block 0: Pure genesis (no virtual MNs)
        // Block 1: Premine with collateral outputs (10k each)
        // After Block 1: Register MNs via ProRegTx referencing block 1 outputs
        //
        // This design is cleaner and compatible with mainnet snapshot approach.
        // MN collateral outputs in block 1:
        //   - Output 1: MN1 (y7L1LfAfdSbMCu9qvvEYd9LHq97FqUPeaM) - 10,000 BATHRON
        //   - Output 2: MN2 (yA3MEDZbpDaPPTUqid6AxAbHd7rjiWvWaN) - 10,000 BATHRON
        //   - Output 3: MN3 (yAi9Rhh4W7e7SnQ5FkdL2bDS5dDDSLiK9r) - 10,000 BATHRON
        //   - Output 4: MN4 (xwmQ3oiDGoondTwdFFA9myZYkpWc4eU7zx) - 10,000 BATHRON
        // ═══════════════════════════════════════════════════════════════════════
        consensus.genesisMNs = {};  // Empty - MNs registered via ProRegTx

        /**
         * The message start string is designed to be unlikely to occur in normal data.
         * The characters are rarely used upper ASCII, not valid as UTF-8, and produce
         * a large 4-byte int at any alignment.
         */
        // BATHRON Testnet Magic Bytes - includes TESTNET_EPOCH to prevent old nodes connecting
        // When creating a new testnet genesis, increment TESTNET_EPOCH in version.h
        // Format: 0xfa 0xbf 0xb5 0x(da + TESTNET_EPOCH)
        pchMessageStart[0] = 0xfa;
        pchMessageStart[1] = 0xbf;
        pchMessageStart[2] = 0xb5;
        pchMessageStart[3] = 0xda + TESTNET_EPOCH;  // Epoch 2 = 0xdc
        nDefaultPort = 27171;  // BATHRON Testnet P2P port

        // vSeeds.emplace_back("pivx-testnet.seed.fuzzbawls.pw", true);
        // vSeeds.emplace_back("pivx-testnet.seed2.fuzzbawls.pw", true);

        base58Prefixes[PUBKEY_ADDRESS] = std::vector<unsigned char>(1, 139); // Testnet bathron addresses start with 'x' or 'y'
        base58Prefixes[SCRIPT_ADDRESS] = std::vector<unsigned char>(1, 19);  // Testnet bathron script addresses start with '8' or '9'
        base58Prefixes[EXCHANGE_ADDRESS] = {0x01, 0xb9, 0xb1};   // EXT prefix for the address
        base58Prefixes[SECRET_KEY] = std::vector<unsigned char>(1, 239);     // Testnet private keys start with '9' or 'c' (Bitcoin defaults)
        // Testnet bathron BIP32 pubkeys start with 'DRKV'
        base58Prefixes[EXT_PUBLIC_KEY] = {0x3a, 0x80, 0x61, 0xa0};
        // Testnet bathron BIP32 prvkeys start with 'DRKP'
        base58Prefixes[EXT_SECRET_KEY] = {0x3a, 0x80, 0x58, 0x37};
        // Testnet bathron BIP44 coin type is '1' (All coin's testnet default)
        base58Prefixes[EXT_COIN_TYPE] = {0x80, 0x00, 0x00, 0x01};

        vFixedSeeds = std::vector<uint8_t>(std::begin(chainparams_seed_test), std::end(chainparams_seed_test));

        fRequireStandard = false;

        // Sapling
        bech32HRPs[SAPLING_PAYMENT_ADDRESS]      = "ptestsapling";
        bech32HRPs[SAPLING_FULL_VIEWING_KEY]     = "pviewtestsapling";
        bech32HRPs[SAPLING_INCOMING_VIEWING_KEY] = "pivktestsapling";
        bech32HRPs[SAPLING_EXTENDED_SPEND_KEY]   = "p-secret-spending-key-test";
        bech32HRPs[SAPLING_EXTENDED_FVK]         = "pxviewtestsapling";

        // Tier two
        nFulfilledRequestExpireTime = 60 * 60; // fulfilled requests expire in 1 hour
    }

    const CCheckpointData& Checkpoints() const
    {
        return dataTestnet;
    }
};

/**
 * PIVHU Regression test - fast local testing
 */
class CRegTestParams : public CChainParams
{
public:
    CRegTestParams()
    {
        strNetworkID = "regtest";

        // PIVHU Regtest Genesis - uses regtest-specific allocations
        // 50M test wallet, 48.5M swap reserve, 500k T, 120k MN = 99.12M total
        // nNonce will be mined by MineGenesisBlock utility
        genesis = CreatePIVHURegtestGenesisBlock(1732924800, 0, 0x207fffff, 1);
        consensus.hashGenesisBlock = genesis.GetHash();

        // PIVHU Regtest genesis hashes - will be updated after compilation
        // assert(consensus.hashGenesisBlock == uint256S("0x..."));
        // assert(genesis.hashMerkleRoot == uint256S("0x..."));
        // ═══════════════════════════════════════════════════════════════════════
        // HU Core Economic Parameters - REGTEST
        // ═══════════════════════════════════════════════════════════════════════
        consensus.nMaxMoneyOut = 99120000 * COIN;   // HU: 99.12M total supply at genesis
        consensus.nMNCollateralAmt = 10000 * COIN;   // 10k M0 = 0.0001 BTC (low for regtest)
        consensus.nMNBlockReward = 0;               // HU: Block reward = 0 (BTC burn-to-mint economy)
        consensus.nNewMNBlockReward = 0;            // HU: Block reward = 0 (BTC burn-to-mint economy)
        consensus.nTargetTimespan = 40 * 60;
        consensus.nTargetTimespanV2 = 30 * 60;
        consensus.nTargetSpacing = 1 * 60;          // HU: 60 second blocks
        consensus.nTimeSlotLength = 15;

        // ═══════════════════════════════════════════════════════════════════════
        // BP30 Timing Parameters - REGTEST (ultra-fast for automated tests)
        // ═══════════════════════════════════════════════════════════════════════

        // Masternode collateral maturity: 1 block (instant for testing)
        consensus.nMasternodeCollateralMinConf = 1;  // Immediate for regtest

        // Masternode vote maturity: 10 blocks (fast for automated tests)
        consensus.nMasternodeVoteMaturityBlocks = 10;  // ~10 minutes

        // Blocks per day (for rate limiting, diagnostics)
        consensus.nBlocksPerDay = 10;               // Ultra-fast for regtest

        // ═══════════════════════════════════════════════════════════════════════
        // HU DMM + Finality Parameters - REGTEST
        // Trivial quorum (1 MN), instant finality for automated tests
        // ═══════════════════════════════════════════════════════════════════════
        consensus.nHuBlockTimeSeconds = 1;          // Virtual (controlled by scripts)
        consensus.nHuQuorumSize = 1;                // Single MN quorum
        consensus.nHuQuorumThreshold = 1;           // 1 signature = finality
        consensus.nHuQuorumRotationBlocks = 1;      // Rotate every block
        consensus.nHuLeaderTimeoutSeconds = 5;      // Short timeout (less relevant in regtest)
        consensus.nHuFallbackRecoverySeconds = 2;   // Ultra-fast for regtest
        consensus.nDMMBootstrapHeight = 2;          // Bootstrap phase (no slot calculation for cold start)
        consensus.nHuMaxReorgDepth = 100;           // Large tolerance for test scenarios
        consensus.nStaleChainTimeout = 60;          // 1 minute for regtest cold start recovery

        // BATHRON: spork system removed - see 03-SPORKS-MODERNIZATION blueprint

        // ═══════════════════════════════════════════════════════════════════════
        // BTC SPV & Burn Parameters - REGTEST
        // All burns detected by burn_claim_daemon
        // ═══════════════════════════════════════════════════════════════════════
        consensus.burnPrefix = "BATHRON1";           // OP_RETURN prefix for burn detection
        consensus.burnScanVoutMin = 0;               // Scan outputs [0..2] for OP_RETURN
        consensus.burnScanVoutMax = 2;
        consensus.burnScanBtcHeightStart = 0;        // REGTEST: Scan all heights
        consensus.burnScanBtcHeightEnd = UINT32_MAX; // REGTEST: No height restriction

        // ALL upgrades active from GENESIS (no height-based activation)
        // This is the BATHRON way: clean start, all features active from block 0
        consensus.vUpgrades[Consensus::BASE_NETWORK].nActivationHeight =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_TESTDUMMY].nActivationHeight =
                Consensus::NetworkUpgrade::NO_ACTIVATION_HEIGHT;
        consensus.vUpgrades[Consensus::UPGRADE_BIP65].nActivationHeight         =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V3_4].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V4_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;  // Sapling version
        consensus.vUpgrades[Consensus::UPGRADE_V5_2].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_3].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_5].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V5_6].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;
        consensus.vUpgrades[Consensus::UPGRADE_V6_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;  // BP30 settlement active from genesis
        consensus.vUpgrades[Consensus::UPGRADE_V7_0].nActivationHeight          =
                Consensus::NetworkUpgrade::ALWAYS_ACTIVE;  // CTV-lite: active on regtest

        /**
         * The message start string is designed to be unlikely to occur in normal data.
         * The characters are rarely used upper ASCII, not valid as UTF-8, and produce
         * a large 4-byte int at any alignment.
         */
        pchMessageStart[0] = 0xa1;
        pchMessageStart[1] = 0xcf;
        pchMessageStart[2] = 0x7e;
        pchMessageStart[3] = 0xac;
        nDefaultPort = 51476;

        base58Prefixes[PUBKEY_ADDRESS] = std::vector<unsigned char>(1, 139); // Testnet bathron addresses start with 'x' or 'y'
        base58Prefixes[SCRIPT_ADDRESS] = std::vector<unsigned char>(1, 19);  // Testnet bathron script addresses start with '8' or '9'
        base58Prefixes[EXCHANGE_ADDRESS] = {0x01, 0xb9, 0xb1};   // EXT prefix for the address
        base58Prefixes[SECRET_KEY] = std::vector<unsigned char>(1, 239);     // Testnet private keys start with '9' or 'c' (Bitcoin defaults)
        // Testnet bathron BIP32 pubkeys start with 'DRKV'
        base58Prefixes[EXT_PUBLIC_KEY] = {0x3a, 0x80, 0x61, 0xa0};
        // Testnet bathron BIP32 prvkeys start with 'DRKP'
        base58Prefixes[EXT_SECRET_KEY] = {0x3a, 0x80, 0x58, 0x37};
        // Testnet bathron BIP44 coin type is '1' (All coin's testnet default)
        base58Prefixes[EXT_COIN_TYPE] = {0x80, 0x00, 0x00, 0x01};

        // Reject non-standard transactions by default
        fRequireStandard = true;

        // Sapling
        bech32HRPs[SAPLING_PAYMENT_ADDRESS]      = "ptestsapling";
        bech32HRPs[SAPLING_FULL_VIEWING_KEY]     = "pviewtestsapling";
        bech32HRPs[SAPLING_INCOMING_VIEWING_KEY] = "pivktestsapling";
        bech32HRPs[SAPLING_EXTENDED_SPEND_KEY]   = "p-secret-spending-key-test";
        bech32HRPs[SAPLING_EXTENDED_FVK]         = "pxviewtestsapling";

        // Tier two
        nFulfilledRequestExpireTime = 60 * 60; // fulfilled requests expire in 1 hour
    }

    const CCheckpointData& Checkpoints() const
    {
        return dataRegtest;
    }
};

static std::unique_ptr<CChainParams> globalChainParams;

const CChainParams &Params()
{
    assert(globalChainParams);
    return *globalChainParams;
}

std::unique_ptr<CChainParams> CreateChainParams(const std::string& chain)
{
    if (chain == CBaseChainParams::MAIN)
        return std::unique_ptr<CChainParams>(new CMainParams());
    else if (chain == CBaseChainParams::TESTNET)
        return std::unique_ptr<CChainParams>(new CTestNetParams());
    else if (chain == CBaseChainParams::REGTEST)
        return std::unique_ptr<CChainParams>(new CRegTestParams());
    throw std::runtime_error(strprintf("%s: Unknown chain %s.", __func__, chain));
}

void SelectParams(const std::string& network)
{
    SelectBaseParams(network);
    globalChainParams = CreateChainParams(network);
}

void UpdateNetworkUpgradeParameters(Consensus::UpgradeIndex idx, int nActivationHeight)
{
    globalChainParams->UpdateNetworkUpgradeParameters(idx, nActivationHeight);
}
