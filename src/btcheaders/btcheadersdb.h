// Copyright (c) 2026 The BATHRON developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#ifndef BATHRON_BTCHEADERSDB_H
#define BATHRON_BTCHEADERSDB_H

/**
 * BTC Headers On-Chain Database (BP-SPVMNPUB)
 *
 * LevelDB storage for BTC headers published via TX_BTC_HEADERS.
 * This is the CONSENSUS source for BTC headers - separate from btcspv (sync).
 *
 * Key Schema:
 *   't' -> (uint32_t height, uint256 hash)   // Current tip
 *   'h' || height (4 bytes BE) -> uint256    // Hash at height
 *   'H' || hash (32 bytes) -> BtcBlockHeader // Header data
 *   'b' -> uint256                           // Best BATHRON block (consistency)
 *   'p' -> (uint256 proTxHash, int height)   // Last publisher (anti-spam)
 *
 * CRITICAL: This DB must be committed atomically with other consensus DBs
 * (settlement, evo, burnclaim) in the final commit phase.
 */

#include "btcspv/btcspv.h"
#include "dbwrapper.h"
#include "uint256.h"

#include <memory>

namespace btcheadersdb {

class CBtcHeadersDB
{
private:
    std::unique_ptr<CDBWrapper> db;
    mutable RecursiveMutex cs;

public:
    explicit CBtcHeadersDB(size_t nCacheSize, bool fMemory = false, bool fWipe = false);
    ~CBtcHeadersDB();

    //==========================================================================
    // Tip Access
    //==========================================================================

    /**
     * Get current on-chain BTC tip.
     *
     * @param heightOut[out] Tip height
     * @param hashOut[out] Tip hash
     * @return true if tip exists, false if DB is empty
     */
    bool GetTip(uint32_t& heightOut, uint256& hashOut) const;

    /**
     * Get tip height only.
     * Returns 0 if DB is empty.
     */
    uint32_t GetTipHeight() const;

    /**
     * Get tip hash only.
     * Returns uint256() if DB is empty.
     */
    uint256 GetTipHash() const;

    //==========================================================================
    // Header Access
    //==========================================================================

    /**
     * Get header by height.
     *
     * @param height BTC block height
     * @param out[out] Header data
     * @return true if found
     */
    bool GetHeaderByHeight(uint32_t height, BtcBlockHeader& out) const;

    /**
     * Get header by hash.
     *
     * @param hash BTC block hash
     * @param out[out] Header data
     * @return true if found
     */
    bool GetHeaderByHash(const uint256& hash, BtcBlockHeader& out) const;

    /**
     * Get hash at height.
     *
     * @param height BTC block height
     * @param out[out] Block hash
     * @return true if found
     */
    bool GetHashAtHeight(uint32_t height, uint256& out) const;

    /**
     * Check if header exists at height.
     */
    bool HasHeaderAtHeight(uint32_t height) const;

    //==========================================================================
    // Consistency
    //==========================================================================

    /**
     * Write best BATHRON block hash (for chain consistency check).
     */
    bool WriteBestBlock(const uint256& blockHash);

    /**
     * Read best BATHRON block hash.
     */
    bool ReadBestBlock(uint256& blockHash) const;

    //==========================================================================
    // Publisher Tracking (anti-spam cooldown)
    //==========================================================================

    /**
     * Get last publisher info.
     *
     * @param proTxHashOut[out] ProTxHash of last publisher
     * @param heightOut[out] BATHRON block height of last publication
     * @return true if found, false if no publication yet
     */
    bool GetLastPublisher(uint256& proTxHashOut, int& heightOut) const;

    //==========================================================================
    // Batch Operations (for atomic commit)
    //==========================================================================

    class Batch
    {
    private:
        CDBBatch batch;
        CBtcHeadersDB& parent;

        // Track tip updates within this batch
        uint32_t newTipHeight{0};
        uint256 newTipHash;
        bool hasTipUpdate{false};

    public:
        explicit Batch(CBtcHeadersDB& db);

        /**
         * Write a header at specified height.
         */
        void WriteHeader(uint32_t height, const BtcBlockHeader& header);

        /**
         * Erase header at specified height.
         */
        void EraseHeader(uint32_t height, const uint256& hash);

        /**
         * Update tip.
         */
        void WriteTip(uint32_t height, const uint256& hash);

        /**
         * Write best BATHRON block hash.
         */
        void WriteBestBlock(const uint256& blockHash);

        /**
         * Write last publisher info (anti-spam tracking).
         */
        void WriteLastPublisher(const uint256& proTxHash, int bathronHeight);

        /**
         * Commit batch to database.
         */
        bool Commit();
    };

    Batch CreateBatch() { return Batch(*this); }

    //==========================================================================
    // Statistics
    //==========================================================================

    struct Stats {
        uint32_t tipHeight;
        uint256 tipHash;
        uint256 bestBathronBlock;
        size_t headerCount;
    };

    Stats GetStats() const;

    // Sync to disk
    bool Sync();

    // Get raw DB wrapper
    CDBWrapper* GetDB() { return db.get(); }
};

} // namespace btcheadersdb

// Global instance
extern std::unique_ptr<btcheadersdb::CBtcHeadersDB> g_btcheadersdb;

/**
 * Initialize the BTC headers database.
 */
bool InitBtcHeadersDB(size_t nCacheSize, bool fMemory = false, bool fWipe = false);

/**
 * Check BTC headers DB consistency with chain tip.
 *
 * @param chainTipHash Current BATHRON chain tip hash
 * @param fRequireRebuild[out] Set to true if rebuild needed
 * @return true if consistent
 */
bool CheckBtcHeadersDBConsistency(const uint256& chainTipHash, bool& fRequireRebuild);

// NOTE: BootstrapBtcHeadersDBFromSPV removed - Block 1 TX_BTC_HEADERS handles this

#endif // BATHRON_BTCHEADERSDB_H
