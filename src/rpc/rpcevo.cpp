// Copyright (c) 2018-2021 The Dash Core developers
// Copyright (c) 2021-2022 The PIVX Core developers
// Distributed under the MIT software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.

#include "masternode/activemasternode.h"
#include "chainparams.h"
#include "core_io.h"
#include "validation.h"
#include "destination_io.h"
#include "masternode/deterministicmns.h"
#include "masternode/specialtx_validation.h"
#include "masternode/providertx.h"
#include "key_io.h"
#include "messagesigner.h"
#include "net/netbase.h"
#include "operationresult.h"
#include "policy/policy.h"
#include "pubkey.h" // COMPACT_SIGNATURE_SIZE
#include "rpc/server.h"
#include "script/sign.h"
#include "masternode/masternode_meta_manager.h"
#include "util/validation.h"
#include "utilmoneystr.h"

#ifdef ENABLE_WALLET
#include "coincontrol.h"
#include "wallet/wallet.h"
#include "wallet/rpcwallet.h"

extern void TryATMP(const CMutableTransaction& mtx, bool fOverrideFees);
extern void RelayTx(const uint256& hashTx);
#endif//ENABLE_WALLET

enum ProRegParam {
    collateralAddress,
    collateralHash,
    collateralIndex,
    ipAndPort_register,
    ipAndPort_update,
    operatorPubKey_register,
    operatorPubKey_update,
    operatorPayoutAddress_register,
    operatorPayoutAddress_update,
    operatorReward,
    operatorKey,
    ownerAddress,
    ownerKey,
    proTxHash,
    payoutAddress_register,
    payoutAddress_update,
    revocationReason,
    votingAddress_register,
    votingAddress_update,
};

static const std::map<ProRegParam, std::string> mapParamHelp = {
        {collateralAddress,
            "%d. \"collateralAddress\"     (string, required) The address to send the collateral to.\n"
        },
        {collateralHash,
            "%d. \"collateralHash\"        (string, required) The collateral transaction hash.\n"
        },
        {collateralIndex,
            "%d. collateralIndex           (numeric, required) The collateral transaction output index.\n"
        },
        {ipAndPort_register,
            "%d. \"ipAndPort\"             (string, required) IP and port in the form \"IP:PORT\".\n"
            "                                Must be unique on the network. Can be set to 0, which will require a ProUpServTx afterwards.\n"
        },
        {ipAndPort_update,
            "%d. \"ipAndPort\"             (string, required) IP and port in the form \"IP:PORT\".\n"
            "                                If set to an empty string, the currently active ip is reused.\n"
        },
        {operatorPubKey_register,
            "%d. \"operatorPubKey\"       (string, required) The operator ECDSA public key. The private key does not have to be known.\n"
            "                              It has to match the private key which is later used when operating the masternode.\n"
        },
        {operatorPubKey_update,
            "%d. \"operatorPubKey\"       (string, required) The operator ECDSA public key. The private key does not have to be known.\n"
            "                                It has to match the private key which is later used when operating the masternode.\n"
            "                                If set to an empty string, the currently active operator public key is reused.\n"
        },
        {operatorKey,
            "%d. \"operatorKey\"           (string, optional) The operator ECDSA private key associated with the\n"
            "                                 registered operator public key. If not specified, or set to an empty string, then this command must\n"
            "                                 be performed on the active masternode with the corresponding operator key.\n"
        },
        {operatorPayoutAddress_register,
            "%d. \"operatorPayoutAddress\" (string, optional) The address used for operator reward payments.\n"
            "                                Only allowed when the ProRegTx had a non-zero operatorReward value.\n"
            "                                If set to an empty string, the operatorPubKey is used.\n"
        },
        {operatorPayoutAddress_update,
            "%d. \"operatorPayoutAddress\" (string, optional) The address used for operator reward payments.\n"
            "                                Only allowed when the ProRegTx had a non-zero operatorReward value.\n"
            "                                If set to an empty string, the currently active one is reused.\n"
        },
        {operatorReward,
            "%d. \"operatorReward\"        (numeric, optional) The fraction in %% to share with the operator. The value must be\n"
            "                                between 0.00 and 100.00. If not set, it takes the default value of 0.0\n"
        },
        {ownerAddress,
            "%d. \"ownerAddress\"          (string, required) The address to use for payee updates and proposal voting.\n"
            "                                The private key belonging to this address must be known in your wallet, in order to send updates.\n"
            "                                The address must not be already registered, and must differ from the collateralAddress\n"
        },
        {ownerKey,
            "%d. \"ownerKey\"              (string, optional) The owner key associated with the operator address of the masternode.\n"
            "                                If not specified, or set to an empty string, then the mn key must be known by your wallet, in order to sign the tx.\n"
        },
        {payoutAddress_register,
            "%d. \"payoutAddress\"          (string, required) The address to use for masternode reward payments.\n"
        },
        {payoutAddress_update,
            "%d. \"payoutAddress\"          (string, required) The address to use for masternode reward payments.\n"
            "                                 If set to an empty string, the currently active payout address is reused.\n"
        },
        {proTxHash,
            "%d. \"proTxHash\"              (string, required) The hash of the initial ProRegTx.\n"
        },
        {revocationReason,
            "%d. reason                     (numeric, optional) The reason for masternode service revocation. Default: 0.\n"
            "                                 0=not_specified, 1=service_termination, 2=compromised_keys, 3=keys_change.\n"
        },
        {votingAddress_register,
            "%d. \"votingAddress\"          (string, required) The voting key address. The private key does not have to be known by your wallet.\n"
            "                                 It has to match the private key which is later used when voting on proposals.\n"
            "                                 If set to an empty string, ownerAddress will be used.\n"
        },
        {votingAddress_update,
            "%d. \"votingAddress\"          (string, required) The voting key address. The private key does not have to be known by your wallet.\n"
            "                                 It has to match the private key which is later used when voting on proposals.\n"
            "                                 If set to an empty string, the currently active voting key address is reused.\n"
        },
    };

std::string GetHelpString(int nParamNum, ProRegParam p)
{
    auto it = mapParamHelp.find(p);
    if (it == mapParamHelp.end())
        throw std::runtime_error(strprintf("FIXME: WRONG PARAM: %d!", (int)p));

    return strprintf(it->second, nParamNum);
}

#ifdef ENABLE_WALLET
static CKey GetKeyFromWallet(CWallet* pwallet, const CKeyID& keyID)
{
    assert(pwallet);
    CKey key;
    if (!pwallet->GetKey(keyID, key)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY,
                           strprintf("key for address %s not in wallet", EncodeDestination(keyID)));
    }
    return key;
}
#endif

static void CheckEvoUpgradeEnforcement()
{
    const int nHeight = WITH_LOCK(cs_main, return chainActive.Height(); );
    if (!Params().GetConsensus().NetworkUpgradeActive(nHeight, Consensus::UPGRADE_V6_0)) {
        throw JSONRPCError(RPC_MISC_ERROR, "Evo upgrade is not active yet");
    }
}

// Allows to specify address or priv key (as strings). In case of address, the priv key is taken from the wallet
static CKey ParsePrivKey(CWallet* pwallet, const std::string &strKeyOrAddress, bool allowAddresses = true) {
    bool isExchange{false}, isShield{false};
    const CWDestination& cwdest = Standard::DecodeDestination(strKeyOrAddress, isExchange, isShield);
    if (isShield) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "shield addresses not supported");
    }
    const CTxDestination* dest = Standard::GetTransparentDestination(cwdest);
    if (allowAddresses && dest && IsValidDestination(*dest)) {
#ifdef ENABLE_WALLET
        if (!pwallet) {
            throw std::runtime_error("addresses not supported when wallet is disabled");
        }
        EnsureWalletIsUnlocked(pwallet);
        const CKeyID* keyID = boost::get<CKeyID>(dest);
        assert (keyID != nullptr);  // we just checked IsValidDestination
        return GetKeyFromWallet(pwallet, *keyID);
#else   // ENABLE_WALLET
        throw std::runtime_error("addresses not supported in no-wallet builds");
#endif  // ENABLE_WALLET
    }

    CKey key = KeyIO::DecodeSecret(strKeyOrAddress);
    if (!key.IsValid()) throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Invalid private key encoding");
    return key;
}

static CKeyID ParsePubKeyIDFromAddress(const std::string& strAddress)
{
    bool isExchange{false}, isShield{false};
    const CWDestination& cwdest = Standard::DecodeDestination(strAddress, isExchange, isShield);
    if (isShield) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "shield addresses not supported");
    }
    const CKeyID* keyID = boost::get<CKeyID>(Standard::GetTransparentDestination(cwdest));
    if (!keyID) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, strprintf("invalid address %s", strAddress));
    }
    return *keyID;
}

static CPubKey ParseECDSAPubKey(const std::string& strKey)
{
    std::vector<unsigned char> vchKey = ParseHex(strKey);
    CPubKey pubKey(vchKey.begin(), vchKey.end());
    if (!pubKey.IsValid()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("invalid ECDSA public key: %s", strKey));
    }
    return pubKey;
}

static CKey ParseECDSASecretKey(const std::string& strKey)
{
    CKey key = KeyIO::DecodeSecret(strKey);
    if (!key.IsValid()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("invalid ECDSA secret key: %s", strKey));
    }
    return key;
}

static CKey GetECDSAOperatorKey(const std::string& strKey)
{
    if (!strKey.empty()) {
        return ParseECDSASecretKey(strKey);
    }
    // If empty, get the active masternode key
    CKey key; CTxIn vin;
    if (!GetActiveDMNKeys(key, vin)) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "Active masternode key not found. Insert DMN operator private key.");
    }
    return key;
}

static UniValue DmnToJson(const CDeterministicMNCPtr dmn)
{
    UniValue ret(UniValue::VOBJ);
    dmn->ToJson(ret);
    Coin coin;
    if (!WITH_LOCK(cs_main, return pcoinsTip->GetUTXOCoin(dmn->collateralOutpoint, coin); )) {
        return ret;
    }
    CTxDestination dest;
    if (!ExtractDestination(coin.out.scriptPubKey, dest)) {
        return ret;
    }
    ret.pushKV("collateralAddress", EncodeDestination(dest));
    return ret;
}

#ifdef ENABLE_WALLET

template<typename SpecialTxPayload>
static void FundSpecialTx(CWallet* pwallet, CMutableTransaction& tx, SpecialTxPayload& payload)
{
    LogPrintf("PROTX-DEBUG: FundSpecialTx ENTER nType=%d\n", (int)tx.nType);
    SetTxPayload(tx, payload);

    static CTxOut dummyTxOut(0, CScript() << OP_RETURN);
    std::vector<CRecipient> vecSend;
    bool dummyTxOutAdded = false;

    if (tx.vout.empty()) {
        // add dummy txout as CreateTransaction requires at least one recipient
        tx.vout.emplace_back(dummyTxOut);
        dummyTxOutAdded = true;
    }

    CAmount nFee;
    CFeeRate feeRate = CFeeRate(0);
    int nChangePos = -1;
    std::string strFailReason;
    std::set<int> setSubtractFeeFromOutputs;
    LogPrintf("PROTX-DEBUG: calling FundTransaction\n");
    if (!pwallet->FundTransaction(tx, nFee, false, feeRate, nChangePos, strFailReason, false, false, {}))
        throw JSONRPCError(RPC_INTERNAL_ERROR, strFailReason);
    LogPrintf("PROTX-DEBUG: FundTransaction OK fee=%lld\n", nFee);

    if (dummyTxOutAdded && tx.vout.size() > 1) {
        // FundTransaction added a change output, so we don't need the dummy txout anymore
        // Removing it results in slight overpayment of fees, but we ignore this for now (as it's a very low amount)
        auto it = std::find(tx.vout.begin(), tx.vout.end(), dummyTxOut);
        assert(it != tx.vout.end());
        tx.vout.erase(it);
    }

    UpdateSpecialTxInputsHash(tx, payload);
}

#endif

template<typename SpecialTxPayload>
static void UpdateSpecialTxInputsHash(const CMutableTransaction& tx, SpecialTxPayload& payload)
{
    payload.inputsHash = CalcTxInputsHash(tx);
}

template<typename SpecialTxPayload>
static void SignSpecialTxPayloadByHash(const CMutableTransaction& tx, SpecialTxPayload& payload, const CKey& key)
{
    payload.vchSig.clear();

    uint256 hash = ::SerializeHash(payload);
    if (!CHashSigner::SignHash(hash, key, payload.vchSig)) {
        throw JSONRPCError(RPC_INTERNAL_ERROR, "failed to sign special tx payload");
    }
}

// All special tx payloads use vchSig member with ECDSA signatures

template<typename SpecialTxPayload>
static void SignSpecialTxPayloadByString(SpecialTxPayload& payload, const CKey& key)
{
    payload.vchSig.clear();

    std::string m = payload.MakeSignString();
    if (!CMessageSigner::SignMessage(m, payload.vchSig, key)) {
        throw JSONRPCError(RPC_INTERNAL_ERROR, "failed to sign special tx payload");
    }
}

static std::string TxInErrorToString(int i, const CTxIn& txin, const std::string& strError)
{
    return strprintf("Input %d (%s): %s", i, txin.prevout.ToStringShort(), strError);
}

#ifdef ENABLE_WALLET

static OperationResult SignTransaction(CWallet* const pwallet, CMutableTransaction& tx)
{
    LOCK2(cs_main, pwallet->cs_wallet);
    const CTransaction txConst(tx);
    for (unsigned int i = 0; i < tx.vin.size(); i++) {
        CTxIn& txin = tx.vin[i];
        const Coin& coin = pcoinsTip->AccessCoin(txin.prevout);
        if (coin.IsSpent()) {
            return errorOut(TxInErrorToString(i, txin, "not found or already spent"));
        }
        SigVersion sv = tx.GetRequiredSigVersion();
        txin.scriptSig.clear();
        SignatureData sigdata;
        if (!ProduceSignature(MutableTransactionSignatureCreator(pwallet, &tx, i, coin.out.nValue, SIGHASH_ALL),
                              coin.out.scriptPubKey, sigdata, sv)) {
            return errorOut(TxInErrorToString(i, txin, "signature failed"));
        }
        UpdateTransaction(tx, i, sigdata);
    }
    return OperationResult(true);
}

template<typename SpecialTxPayload>
static std::string SignAndSendSpecialTx(CWallet* const pwallet, CMutableTransaction& tx, const SpecialTxPayload& pl)
{
    SetTxPayload(tx, pl);

    CValidationState state;
    CCoinsViewCache view(pcoinsTip.get());
    if (!WITH_LOCK(cs_main, return CheckSpecialTx(tx, GetChainTip(), &view, state); )) {
        throw JSONRPCError(RPC_MISC_ERROR, FormatStateMessage(state));
    }

    const OperationResult& sigRes = SignTransaction(pwallet, tx);
    if (!sigRes) {
        throw JSONRPCError(RPC_INTERNAL_ERROR, sigRes.getError());
    }

    TryATMP(tx, false);
    const uint256& hashTx = tx.GetHash();
    RelayTx(hashTx);
    return hashTx.GetHex();
}

// Parses inputs (starting from index paramIdx) and returns ProReg payload
static ProRegPL ParseProRegPLParams(const UniValue& params, unsigned int paramIdx)
{
    assert(params.size() > paramIdx + 4);
    assert(params.size() < paramIdx + 8);
    const auto& chainparams = Params();
    ProRegPL pl;

    // ip and port
    const std::string& strIpPort = params[paramIdx].get_str();
    if (!strIpPort.empty()) {
        if (!Lookup(strIpPort, pl.addr, chainparams.GetDefaultPort(), false)) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("invalid network address %s", strIpPort));
        }
    }

    // addresses/keys
    const std::string& strAddOwner = params[paramIdx + 1].get_str();
    const std::string& strPubKeyOperator = params[paramIdx + 2].get_str();
    const std::string& strAddVoting = params[paramIdx + 3].get_str();
    pl.keyIDOwner = ParsePubKeyIDFromAddress(strAddOwner);
    pl.pubKeyOperator = ParseECDSAPubKey(strPubKeyOperator);
    pl.keyIDVoting = pl.keyIDOwner;
    if (!strAddVoting.empty()) {
        pl.keyIDVoting = ParsePubKeyIDFromAddress(strAddVoting);
    }

    // payout script
    const std::string& strAddPayee = params[paramIdx + 4].get_str();
    pl.scriptPayout = GetScriptForDestination(CTxDestination(ParsePubKeyIDFromAddress(strAddPayee)));

    // operator reward
    pl.nOperatorReward = 0;
    if (params.size() > paramIdx + 5) {
        int64_t operReward = 0;
        if (!ParseFixedPoint(params[paramIdx + 5].getValStr(), 2, &operReward)) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "operatorReward must be a number");
        }
        if (operReward < 0 || operReward > 10000) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "operatorReward must be between 0.00 and 100.00");
        }
        pl.nOperatorReward = (uint16_t)operReward;
        if (params.size() > paramIdx + 6) {
            // operator reward payout script
            const std::string& strAddOpPayee = params[paramIdx + 6].get_str();
            if (pl.nOperatorReward > 0 && !strAddOpPayee.empty()) {
                pl.scriptOperatorPayout = GetScriptForDestination(CTxDestination(ParsePubKeyIDFromAddress(strAddOpPayee)));
            } else if (!strAddOpPayee.empty()) {
                throw JSONRPCError(RPC_INVALID_PARAMETER, "operatorPayoutAddress must be empty when operatorReward is 0");
            }
        }
    }
    return pl;
}

// handles protx_register, and protx_register_prepare
static UniValue ProTxRegister(const JSONRPCRequest& request, bool fSignAndSend)
{
    CWallet * const pwallet = GetWalletForJSONRPCRequest(request);

    if (!EnsureWalletIsAvailable(pwallet, request.fHelp))
        return NullUniValue;

    if (request.fHelp || request.params.size() < 7 || request.params.size() > 9) {
        throw std::runtime_error(
                (fSignAndSend ?
                    "protx_register \"collateralHash\" collateralIndex \"ipAndPort\" \"ownerAddress\" \"operatorPubKey\" \"votingAddress\" \"payoutAddress\" (operatorReward \"operatorPayoutAddress\")\n"
                    "The collateral is specified through \"collateralHash\" and \"collateralIndex\" and must be an unspent\n"
                    "transaction output spendable by this wallet. It must also not be used by any other masternode.\n"
                        :
                    "protx_register_prepare \"collateralHash\" collateralIndex \"ipAndPort\" \"ownerAddress\" \"operatorPubKey\" \"votingAddress\" \"payoutAddress\" (operatorReward \"operatorPayoutAddress\")\n"
                    "\nCreates an unsigned ProTx and returns it. The ProTx must be signed externally with the collateral\n"
                    "key and then passed to \"protx_register_submit\".\n"
                    "The collateral is specified through \"collateralHash\" and \"collateralIndex\" and must be an unspent transaction output.\n"
                )
                + HelpRequiringPassphrase(pwallet) + "\n"
                "\nArguments:\n"
                + GetHelpString(1, collateralHash)
                + GetHelpString(2, collateralIndex)
                + GetHelpString(3, ipAndPort_register)
                + GetHelpString(4, ownerAddress)
                + GetHelpString(5, operatorPubKey_register)
                + GetHelpString(6, votingAddress_register)
                + GetHelpString(7, payoutAddress_register)
                + GetHelpString(8, operatorReward)
                + GetHelpString(9, operatorPayoutAddress_register) +
                "\nResult:\n" +
                (fSignAndSend ? (
                        "\"txid\"                 (string) The transaction id.\n"
                        "\nExamples:\n"
                        + HelpExampleCli("protx_register", "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\" 0 \"168.192.1.100:51472\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\"")
                        ) : (
                        "{                        (json object)\n"
                        "  \"tx\" :                 (string) The serialized ProTx in hex format.\n"
                        "  \"collateralAddress\" :  (string) The collateral address.\n"
                        "  \"signMessage\" :        (string) The string message that needs to be signed with the collateral key\n"
                        "}\n"
                        "\nExamples:\n"
                        + HelpExampleCli("protx_register_prepare", "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\" 0 \"168.192.1.100:51472\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\"")
                        )
                )
        );
    }
    if (fSignAndSend) CheckEvoUpgradeEnforcement();

    EnsureWalletIsUnlocked(pwallet);
    // Skip BlockUntilSyncedToCurrentChain during bootstrap to avoid deadlock
    // with validation queue when generatebootstrap drives block creation.
    {
        LOCK(cs_main);
        if (chainActive.Height() > Params().GetConsensus().nDMMBootstrapHeight) {
            pwallet->BlockUntilSyncedToCurrentChain();
        }
    }

    LogPrintf("PROTX-DEBUG: ProTxRegister ENTER\n");

    const uint256& collateralHash = ParseHashV(request.params[0], "collateralHash");
    const int32_t collateralIndex = request.params[1].get_int();
    if (collateralIndex < 0) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("invalid collateral index (negative): %d", collateralIndex));
    }

    LogPrintf("PROTX-DEBUG: collateral=%s:%d\n", collateralHash.ToString().substr(0,16), collateralIndex);

    ProRegPL pl = ParseProRegPLParams(request.params, 2);
    pl.nVersion = ProRegPL::CURRENT_VERSION;
    pl.collateralOutpoint = COutPoint(collateralHash, (uint32_t)collateralIndex);

    CMutableTransaction tx;
    tx.nVersion = CTransaction::TxVersion::SAPLING;
    tx.nType = CTransaction::TxType::PROREG;

    // referencing unspent collateral outpoint
    Coin coin;
    if (!WITH_LOCK(cs_main, return pcoinsTip->GetUTXOCoin(pl.collateralOutpoint, coin); )) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("collateral not found: %s-%d", collateralHash.ToString(), collateralIndex));
    }
    LogPrintf("PROTX-DEBUG: coin value=%lld\n", coin.out.nValue);
    if (coin.out.nValue != Params().GetConsensus().nMNCollateralAmt) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("collateral %s-%d with invalid value %d", collateralHash.ToString(), collateralIndex, coin.out.nValue));
    }
    CTxDestination txDest;
    ExtractDestination(coin.out.scriptPubKey, txDest);
    const CKeyID* keyID = boost::get<CKeyID>(&txDest);
    if (!keyID) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("collateral type not supported: %s-%d", collateralHash.ToString(), collateralIndex));
    }
    LogPrintf("PROTX-DEBUG: collateral owner=%s, fSignAndSend=%d\n", EncodeDestination(txDest), fSignAndSend);
    CKey keyCollateral;
    LogPrintf("PROTX-DEBUG: calling GetKey...\n");
    bool hasKey = pwallet->GetKey(*keyID, keyCollateral);
    LogPrintf("PROTX-DEBUG: GetKey returned %d\n", hasKey);
    if (fSignAndSend && !hasKey) {
        LogPrintf("PROTX-DEBUG: THROWING collateral key not in wallet\n");
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, strprintf("collateral key not in wallet: %s", EncodeDestination(txDest)));
    }
    LogPrintf("PROTX-DEBUG: key OK, calling FundSpecialTx\n");

    // make sure fee calculation works
    pl.vchSig.resize(CPubKey::COMPACT_SIGNATURE_SIZE);

    FundSpecialTx(pwallet, tx, pl);
    LogPrintf("PROTX-DEBUG: FundSpecialTx OK\n");

    if (fSignAndSend) {
        SignSpecialTxPayloadByString(pl, keyCollateral); // prove we own the collateral
        // check the payload, add the tx inputs sigs, and send the tx.
        return SignAndSendSpecialTx(pwallet, tx, pl);
    }
    // external signing with collateral key
    pl.vchSig.clear();
    SetTxPayload(tx, pl);
    UniValue ret(UniValue::VOBJ);
    ret.pushKV("tx", EncodeHexTx(tx));
    ret.pushKV("collateralAddress", EncodeDestination(txDest));
    ret.pushKV("signMessage", pl.MakeSignString());
    return ret;
}

UniValue protx_register(const JSONRPCRequest& request)
{
    return ProTxRegister(request, true);
}

UniValue protx_register_prepare(const JSONRPCRequest& request)
{
    return ProTxRegister(request, false);
}

UniValue protx_register_submit(const JSONRPCRequest& request)
{
    CWallet * const pwallet = GetWalletForJSONRPCRequest(request);

    if (!EnsureWalletIsAvailable(pwallet, request.fHelp))
        return NullUniValue;

    if (request.fHelp || request.params.size() != 2) {
        throw std::runtime_error(
                "protx_register_submit \"tx\" \"sig\"\n"
                "\nSubmits the specified ProTx to the network. This command will also sign the inputs of the transaction\n"
                "which were previously added by \"protx_register_prepare\" to cover transaction fees\n"
                + HelpRequiringPassphrase(pwallet) + "\n"
                "\nArguments:\n"
                "1. \"tx\"                 (string, required) The serialized transaction previously returned by \"protx_register_prepare\"\n"
                "2. \"sig\"                (string, required) The signature signed with the collateral key. Must be in base64 format.\n"
                "\nResult:\n"
                "\"txid\"                  (string) The transaction id.\n"
                "\nExamples:\n"
                + HelpExampleCli("protx_register_submit", "\"tx\" \"sig\"")
        );
    }
    CheckEvoUpgradeEnforcement();

    EnsureWalletIsUnlocked(pwallet);
    // Make sure the results are valid at least up to the most recent block
    // the user could have gotten from another RPC command prior to now
    pwallet->BlockUntilSyncedToCurrentChain();

    CMutableTransaction tx;
    if (!DecodeHexTx(tx, request.params[0].get_str())) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "transaction not deserializable");
    }
    if (tx.nType != CTransaction::TxType::PROREG) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "transaction not a ProRegTx");
    }
    ProRegPL pl;
    if (!GetTxPayload(tx, pl)) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "transaction payload not deserializable");
    }
    if (!pl.vchSig.empty()) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "payload signature not empty");
    }

    pl.vchSig = DecodeBase64(request.params[1].get_str().c_str());

    // check the payload, add the tx inputs sigs, and send the tx.
    return SignAndSendSpecialTx(pwallet, tx, pl);
}

UniValue protx_register_fund(const JSONRPCRequest& request)
{
    CWallet * const pwallet = GetWalletForJSONRPCRequest(request);

    if (!EnsureWalletIsAvailable(pwallet, request.fHelp))
        return NullUniValue;

    if (request.fHelp || request.params.size() < 6 || request.params.size() > 8) {
        throw std::runtime_error(
                "protx_register_fund \"collateralAddress\" \"ipAndPort\" \"ownerAddress\" \"operatorPubKey\" \"votingAddress\" \"payoutAddress\" (operatorReward \"operatorPayoutAddress\")\n"
                "\nCreates, funds and sends a ProTx to the network. The resulting transaction will move 10000 M0\n"
                "to the address specified by collateralAddress and will then function as masternode collateral.\n"
                + HelpRequiringPassphrase(pwallet) + "\n"
                "\nArguments:\n"
                + GetHelpString(1, collateralAddress)
                + GetHelpString(2, ipAndPort_register)
                + GetHelpString(3, ownerAddress)
                + GetHelpString(4, operatorPubKey_register)
                + GetHelpString(5, votingAddress_register)
                + GetHelpString(6, payoutAddress_register)
                + GetHelpString(7, operatorReward)
                + GetHelpString(8, operatorPayoutAddress_register) +
                "\nResult:\n"
                "\"txid\"                        (string) The transaction id.\n"
                "\nExamples:\n"
                + HelpExampleCli("protx_register_fund", "\"DKHHBsuU9zfxxxVaqqqQqK4MxZg6vzpf8\" \"168.192.1.100:51472\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\"")
        );
    }
    CheckEvoUpgradeEnforcement();

    EnsureWalletIsUnlocked(pwallet);
    // Make sure the results are valid at least up to the most recent block
    // the user could have gotten from another RPC command prior to now
    pwallet->BlockUntilSyncedToCurrentChain();

    const CTxDestination& collateralDest(ParsePubKeyIDFromAddress(request.params[0].get_str()));
    const CScript& collateralScript = GetScriptForDestination(collateralDest);
    const CAmount collAmt = Params().GetConsensus().nMNCollateralAmt;

    ProRegPL pl = ParseProRegPLParams(request.params, 1);
    pl.nVersion = ProRegPL::CURRENT_VERSION;

    CMutableTransaction tx;
    tx.nVersion = CTransaction::TxVersion::SAPLING;
    tx.nType = CTransaction::TxType::PROREG;
    tx.vout.emplace_back(collAmt, collateralScript);

    FundSpecialTx(pwallet, tx, pl);

    for (uint32_t i = 0; i < tx.vout.size(); i++) {
        if (tx.vout[i].nValue == collAmt && tx.vout[i].scriptPubKey == collateralScript) {
            pl.collateralOutpoint.n = i;
            break;
        }
    }
    assert(pl.collateralOutpoint.n != (uint32_t) -1);
    // update payload on tx (with final collateral outpoint)
    pl.vchSig.clear();
    // check the payload, add the tx inputs sigs, and send the tx.
    return SignAndSendSpecialTx(pwallet, tx, pl);
}

// ============================================================================
// Blueprint 17: Batch Registration
// ============================================================================

UniValue protx_register_batch(const JSONRPCRequest& request)
{
    CWallet * const pwallet = GetWalletForJSONRPCRequest(request);

    if (!EnsureWalletIsAvailable(pwallet, request.fHelp))
        return NullUniValue;

    if (request.fHelp || request.params.size() < 4 || request.params.size() > 5) {
        throw std::runtime_error(
                "protx_register_batch \"ipAndPort\" \"operatorPubKey\" \"payoutAddress\" count\n"
                "\nRegisters multiple masternodes for the same operator in a single command.\n"
                "Auto-generates unique owner, voting, and collateral addresses for each MN.\n"
                + HelpRequiringPassphrase(pwallet) + "\n"
                "\nArguments:\n"
                "1. \"ipAndPort\"        (string, required) IP and port for the operator (e.g. \"51.75.31.44:27171\")\n"
                "2. \"operatorPubKey\"   (string, required) Operator public key (shared across all MNs)\n"
                "3. \"payoutAddress\"    (string, required) Payout address (shared across all MNs)\n"
                "4. count                (number, required) Number of masternodes to register (1-100)\n"
                "\nResult:\n"
                "{\n"
                "  \"success\": true,\n"
                "  \"count\": n,\n"
                "  \"totalCost\": \"n BATHRON\",\n"
                "  \"txids\": [...],\n"
                "  \"masternodes\": [...]\n"
                "}\n"
                "\nExamples:\n"
                + HelpExampleCli("protx_register_batch", "\"51.75.31.44:27171\" \"03368dea7adae8e200709219ba3c4225f4a78b21078a0d747bc16aea0f88180389\" \"yPayoutAddress\" 5")
        );
    }
    CheckEvoUpgradeEnforcement();

    EnsureWalletIsUnlocked(pwallet);
    pwallet->BlockUntilSyncedToCurrentChain();

    const auto& chainparams = Params();
    const CAmount collAmt = chainparams.GetConsensus().nMNCollateralAmt;

    // Parse parameters
    const std::string& strIpPort = request.params[0].get_str();
    const std::string& strPubKeyOperator = request.params[1].get_str();
    const std::string& strPayoutAddress = request.params[2].get_str();
    int count = request.params[3].get_int();

    // Validate count
    if (count < 1 || count > 100) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "count must be between 1 and 100");
    }

    // Validate operator pubkey
    CPubKey operatorPubKey = ParseECDSAPubKey(strPubKeyOperator);

    // Validate IP
    CService addr;
    if (!strIpPort.empty()) {
        if (!Lookup(strIpPort, addr, chainparams.GetDefaultPort(), false)) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("invalid network address %s", strIpPort));
        }
    }

    // Validate payout address
    CTxDestination payoutDest = DecodeDestination(strPayoutAddress);
    if (!IsValidDestination(payoutDest)) {
        throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, strprintf("invalid payout address: %s", strPayoutAddress));
    }
    CScript payoutScript = GetScriptForDestination(payoutDest);

    // Check wallet has enough funds
    CAmount totalRequired = count * (collAmt + COIN); // collateral + ~1 M0 fee per MN
    CAmount availableBalance = pwallet->GetAvailableBalance();
    if (availableBalance < totalRequired) {
        throw JSONRPCError(RPC_WALLET_INSUFFICIENT_FUNDS,
            strprintf("Insufficient funds. Need %s BATHRON to register %d MNs, have %s BATHRON",
                FormatMoney(totalRequired), count, FormatMoney(availableBalance)));
    }

    UniValue result(UniValue::VOBJ);
    UniValue txids(UniValue::VARR);
    UniValue masternodes(UniValue::VARR);

    // Register each MN
    for (int i = 0; i < count; i++) {
        // Generate new addresses for this MN
        std::string labelOwner = strprintf("mn_batch_owner_%d", i);
        std::string labelVoting = strprintf("mn_batch_voting_%d", i);
        std::string labelCollateral = strprintf("mn_batch_collateral_%d", i);

        // Get new addresses from wallet
        CPubKey newOwnerKey;
        CPubKey newVotingKey;
        CPubKey newCollateralKey;

        if (!pwallet->GetKeyFromPool(newOwnerKey, false)) {
            throw JSONRPCError(RPC_WALLET_KEYPOOL_RAN_OUT, "Error: Keypool ran out, please call keypoolrefill first");
        }
        if (!pwallet->GetKeyFromPool(newVotingKey, false)) {
            throw JSONRPCError(RPC_WALLET_KEYPOOL_RAN_OUT, "Error: Keypool ran out, please call keypoolrefill first");
        }
        if (!pwallet->GetKeyFromPool(newCollateralKey, false)) {
            throw JSONRPCError(RPC_WALLET_KEYPOOL_RAN_OUT, "Error: Keypool ran out, please call keypoolrefill first");
        }

        // Set labels
        pwallet->SetAddressBook(newOwnerKey.GetID(), labelOwner, AddressBook::AddressBookPurpose::RECEIVE);
        pwallet->SetAddressBook(newVotingKey.GetID(), labelVoting, AddressBook::AddressBookPurpose::RECEIVE);
        pwallet->SetAddressBook(newCollateralKey.GetID(), labelCollateral, AddressBook::AddressBookPurpose::RECEIVE);

        CTxDestination collateralDest = newCollateralKey.GetID();
        CScript collateralScript = GetScriptForDestination(collateralDest);

        // Build ProRegPL
        ProRegPL pl;
        pl.nVersion = ProRegPL::CURRENT_VERSION;
        pl.addr = addr;
        pl.keyIDOwner = newOwnerKey.GetID();
        pl.pubKeyOperator = operatorPubKey;
        pl.keyIDVoting = newVotingKey.GetID();
        pl.scriptPayout = payoutScript;
        pl.nOperatorReward = 0;

        // Create transaction
        CMutableTransaction tx;
        tx.nVersion = CTransaction::TxVersion::SAPLING;
        tx.nType = CTransaction::TxType::PROREG;
        tx.vout.emplace_back(collAmt, collateralScript);

        FundSpecialTx(pwallet, tx, pl);

        // Find collateral output index
        for (uint32_t j = 0; j < tx.vout.size(); j++) {
            if (tx.vout[j].nValue == collAmt && tx.vout[j].scriptPubKey == collateralScript) {
                pl.collateralOutpoint.n = j;
                break;
            }
        }
        assert(pl.collateralOutpoint.n != (uint32_t) -1);

        pl.vchSig.clear();

        // Sign and send
        UniValue txResult = SignAndSendSpecialTx(pwallet, tx, pl);
        std::string txid = txResult.get_str();
        txids.push_back(txid);

        // Record MN info
        UniValue mnInfo(UniValue::VOBJ);
        mnInfo.pushKV("mn", i + 1);
        mnInfo.pushKV("txid", txid);
        mnInfo.pushKV("ownerAddress", EncodeDestination(newOwnerKey.GetID()));
        mnInfo.pushKV("votingAddress", EncodeDestination(newVotingKey.GetID()));
        mnInfo.pushKV("collateralAddress", EncodeDestination(collateralDest));
        masternodes.push_back(mnInfo);
    }

    result.pushKV("success", true);
    result.pushKV("count", count);
    result.pushKV("totalCost", strprintf("%s BATHRON", FormatMoney(count * collAmt)));
    result.pushKV("operatorPubKey", strPubKeyOperator);
    result.pushKV("payoutAddress", strPayoutAddress);
    result.pushKV("txids", txids);
    result.pushKV("masternodes", masternodes);

    return result;
}

#endif  //ENABLE_WALLET

static bool CheckWalletOwnsScript(CWallet* pwallet, const CScript& script)
{
#ifdef ENABLE_WALLET
    if (!pwallet)
        return false;
    AssertLockHeld(pwallet->cs_wallet);
    CTxDestination dest;
    if (ExtractDestination(script, dest)) {
        const CKeyID* keyID = boost::get<CKeyID>(&dest);
        if (keyID && pwallet->HaveKey(*keyID))
            return true;
        const CScriptID* scriptID = boost::get<CScriptID>(&dest);
        if (scriptID && pwallet->HaveCScript(*scriptID))
            return true;
    }
    return false;
#else
    return false;
#endif
}

static UniValue ToJson(const CMasternodeMetaInfoPtr& info)
{
    UniValue ret(UniValue::VOBJ);
    auto now = GetAdjustedTime();
    auto lastAttempt = info->GetLastOutboundAttempt();
    auto lastSuccess = info->GetLastOutboundSuccess();
    ret.pushKV("last_outbound_attempt", lastAttempt);
    ret.pushKV("last_outbound_attempt_elapsed", now - lastAttempt);
    ret.pushKV("last_outbound_success", lastSuccess);
    ret.pushKV("last_outbound_success_elapsed", now - lastSuccess);
    return ret;
}

static void AddDMNEntryToList(UniValue& ret, CWallet* pwallet, const CDeterministicMNCPtr& dmn, bool fVerbose, bool fFromWallet)
{
    assert(!fFromWallet || pwallet);
    assert(ret.isArray());

    bool hasOwnerKey{false};
    bool hasVotingKey{false};
    bool ownsCollateral{false};
    bool ownsPayeeScript{false};

    // No need to check wallet if not wallet_only and not verbose
    bool skipWalletCheck = !fFromWallet && !fVerbose;

    if (pwallet && !skipWalletCheck) {
        LOCK(pwallet->cs_wallet);
        hasOwnerKey = pwallet->HaveKey(dmn->pdmnState->keyIDOwner);
        hasVotingKey = pwallet->HaveKey(dmn->pdmnState->keyIDVoting);
        ownsPayeeScript = CheckWalletOwnsScript(pwallet, dmn->pdmnState->scriptPayout);
        CTransactionRef collTx;
        uint256 hashBlock;
        if (GetTransaction(dmn->collateralOutpoint.hash, collTx, hashBlock, true)) {
            ownsCollateral = CheckWalletOwnsScript(pwallet, collTx->vout[dmn->collateralOutpoint.n].scriptPubKey);
        }
    }

    if (fFromWallet && !hasOwnerKey && !hasVotingKey && !ownsCollateral && !ownsPayeeScript) {
        // not one of ours
        return;
    }

    if (fVerbose) {
        UniValue o = DmnToJson(dmn);
        int confs = WITH_LOCK(cs_main, return pcoinsTip->GetCoinDepthAtHeight(dmn->collateralOutpoint, chainActive.Height()); );
        o.pushKV("confirmations", confs);
        o.pushKV("has_owner_key", hasOwnerKey);
        o.pushKV("has_voting_key", hasVotingKey);
        o.pushKV("owns_collateral", ownsCollateral);
        o.pushKV("owns_payee_script", ownsPayeeScript);
        // net info
        auto metaInfo = g_mmetaman.GetMetaInfo(dmn->proTxHash);
        if (metaInfo) o.pushKV("metaInfo", ToJson(metaInfo));
        ret.push_back(o);
    } else {
        ret.push_back(dmn->proTxHash.ToString());
    }
}

UniValue protx_list(const JSONRPCRequest& request)
{
    if (request.fHelp || request.params.size() > 4) {
        throw std::runtime_error(
                "protx_list (detailed wallet_only valid_only height)\n"
                "\nLists all ProTxs.\n"
                "\nArguments:\n"
                "1. \"detailed\"               (bool, optional, default=true) Return detailed information about each protx.\n"
                "                                 If set to false, return only the list of txids.\n"
                "2. \"wallet_only\"            (bool, optional, default=false) If set to true, return only protx which involves\n"
                "                                 keys from this wallet (collateral, owner, operator, voting, or payout addresses).\n"
                "3. \"valid_only\"             (bool, optional, default=false) If set to true, return only ProTx which are active/valid\n"
                "                                 at the height specified.\n"
                "4. \"height\"                 (numeric, optional) If height is not specified, it defaults to the current chain-tip.\n"
                "\nResult:\n"
                "[...]                         (list) List of protx txids or, if detailed=true, list of json objects.\n"
                "\nExamples:\n"
                + HelpExampleCli("protx_list", "")
                + HelpExampleCli("protx_list", "true false false 200000")
        );
    }

    CheckEvoUpgradeEnforcement();

#ifdef ENABLE_WALLET
    CWallet* const pwallet = GetWalletForJSONRPCRequest(request);
#else
    CWallet* const pwallet = nullptr;
#endif

    const bool fVerbose = (request.params.size() == 0 || request.params[0].get_bool());
    const bool fFromWallet = (request.params.size() > 1 && request.params[1].get_bool());
    const bool fValidOnly = (request.params.size() > 2 && request.params[2].get_bool());

    if (fFromWallet && !pwallet) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "wallet_only not supported when wallet is disabled");
    }

    // Get a reference to the block index at the specified height (or at the chain tip)
    const CBlockIndex* pindex;
    {
        LOCK(cs_main);
        const CBlockIndex* pindexTip = chainActive.Tip();
        if (request.params.size() > 3) {
            const int height = request.params[3].get_int();
            if (height <= 0 || height > pindexTip->nHeight) {
                throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("height must be between 1 and %d", pindexTip->nHeight));
            }
            pindexTip = chainActive[height];
        }
        pindex = mapBlockIndex.at(pindexTip->GetBlockHash());
    }

    // Get the deterministic mn list at the index
    CDeterministicMNList mnList = deterministicMNManager->GetListForBlock(pindex);

    // Build/filter the list
    UniValue ret(UniValue::VARR);
    mnList.ForEachMN(fValidOnly, [&](const CDeterministicMNCPtr& dmn) {
        AddDMNEntryToList(ret, pwallet, dmn, fVerbose, fFromWallet);
    });
    return ret;
}

#ifdef ENABLE_WALLET
UniValue protx_update_service(const JSONRPCRequest& request)
{
    CWallet * const pwallet = GetWalletForJSONRPCRequest(request);

    if (!EnsureWalletIsAvailable(pwallet, request.fHelp))
        return NullUniValue;

    if (request.fHelp || request.params.size() < 2 || request.params.size() > 4) {
        throw std::runtime_error(
                "protx_update_service \"proTxHash\" \"ipAndPort\" (\"operatorPayoutAddress\" \"operatorKey\")\n"
                "\nCreates and sends a ProUpServTx to the network. This will update the IP address\n"
                "of a masternode, and/or the operator payout address.\n"
                "If the IP is changed for a masternode that got PoSe-banned, the ProUpServTx will also revive this masternode.\n"
                + HelpRequiringPassphrase(pwallet) + "\n"
                "\nArguments:\n"
                + GetHelpString(1, proTxHash)
                + GetHelpString(2, ipAndPort_update)
                + GetHelpString(3, operatorPayoutAddress_update)
                + GetHelpString(4, operatorKey) +
                "\nResult:\n"
                "\"txid\"                        (string) The transaction id.\n"
                "\nExamples:\n"
                + HelpExampleCli("protx_update_service", "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\" \"168.192.1.100:51472\"")
        );
    }
    CheckEvoUpgradeEnforcement();

    EnsureWalletIsUnlocked(pwallet);
    // Make sure the results are valid at least up to the most recent block
    // the user could have gotten from another RPC command prior to now
    pwallet->BlockUntilSyncedToCurrentChain();

    ProUpServPL pl;
    pl.nVersion = ProUpServPL::CURRENT_VERSION;
    pl.proTxHash = ParseHashV(request.params[0], "proTxHash");

    auto dmn = deterministicMNManager->GetListAtChainTip().GetMN(pl.proTxHash);
    if (!dmn) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("masternode with hash %s not found", pl.proTxHash.ToString()));
    }
    const auto& chainparams = Params();
    const std::string& addrStr = request.params[1].get_str();
    if (!addrStr.empty()) {
        if (!Lookup(addrStr.c_str(), pl.addr, chainparams.GetDefaultPort(), false)) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("invalid network address %s", addrStr));
        }
    } else {
        pl.addr = dmn->pdmnState->addr;
    }
    pl.scriptOperatorPayout = dmn->pdmnState->scriptOperatorPayout;
    if (request.params.size() > 2) {
        const std::string& strAddOpPayee = request.params[2].get_str();
        if (!strAddOpPayee.empty()) {
            if (dmn->nOperatorReward > 0) {
                pl.scriptOperatorPayout = GetScriptForDestination(CTxDestination(ParsePubKeyIDFromAddress(strAddOpPayee)));
            } else {
                throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("Operator reward is 0. Cannot set operator payout address"));
            }
        }
    }

    const std::string& strOpKey = request.params.size() > 3 ? request.params[3].get_str() : "";
    CKey operatorKey = GetECDSAOperatorKey(strOpKey);

    CMutableTransaction tx;
    tx.nVersion = CTransaction::TxVersion::SAPLING;
    tx.nType = CTransaction::TxType::PROUPSERV;

    FundSpecialTx(pwallet, tx, pl);
    SignSpecialTxPayloadByHash(tx, pl, operatorKey);

    return SignAndSendSpecialTx(pwallet, tx, pl);
}

UniValue protx_update_registrar(const JSONRPCRequest& request)
{
    CWallet * const pwallet = GetWalletForJSONRPCRequest(request);

    if (!EnsureWalletIsAvailable(pwallet, request.fHelp))
        return NullUniValue;

    if (request.fHelp || request.params.size() < 4 || request.params.size() > 5) {
        throw std::runtime_error(
                "protx update_registrar \"proTxHash\" \"operatorPubKey\" \"votingAddress\" \"payoutAddress\" (\"ownerKey\")\n"
                "\nCreates and sends a ProUpRegTx to the network. This will update the operator key, voting key and payout\n"
                "address of the masternode specified by \"proTxHash\".\n"
                "The owner key of this masternode must be known to your wallet.\n"
                + HelpRequiringPassphrase(pwallet) + "\n"
                "\nArguments:\n"
                + GetHelpString(1, proTxHash)
                + GetHelpString(2, operatorPubKey_update)
                + GetHelpString(3, votingAddress_update)
                + GetHelpString(4, payoutAddress_update)
                + GetHelpString(5, ownerKey) +
                "\nResult:\n"
                "\"txid\"                        (string) The transaction id.\n"
                "\nExamples:\n"
                + HelpExampleCli("protx_update_registrar", "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\" \"DMJRSsuU9zfyrvxVaAEFQqK4MxZg6vgeS6\"")
        );
    }
    CheckEvoUpgradeEnforcement();
    EnsureWalletIsUnlocked(pwallet);
    // Make sure the results are valid at least up to the most recent block
    // the user could have gotten from another RPC command prior to now
    pwallet->BlockUntilSyncedToCurrentChain();

    ProUpRegPL pl;
    pl.nVersion = ProUpServPL::CURRENT_VERSION;
    pl.proTxHash = ParseHashV(request.params[0], "proTxHash");

    auto dmn = deterministicMNManager->GetListAtChainTip().GetMN(pl.proTxHash);
    if (!dmn) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("masternode with hash %s not found", pl.proTxHash.ToString()));
    }
    const std::string& strPubKeyOperator = request.params[1].get_str();
    pl.pubKeyOperator = strPubKeyOperator.empty() ? dmn->pdmnState->pubKeyOperator
                                                  : ParseECDSAPubKey(strPubKeyOperator);

    const std::string& strVotingAddress = request.params[2].get_str();
    pl.keyIDVoting = strVotingAddress.empty() ? dmn->pdmnState->keyIDVoting
                                              : ParsePubKeyIDFromAddress(strVotingAddress);

    const std::string& strPayee = request.params[3].get_str();
    pl.scriptPayout = strPayee.empty() ? pl.scriptPayout = dmn->pdmnState->scriptPayout
                                       : GetScriptForDestination(CTxDestination(ParsePubKeyIDFromAddress(strPayee)));

    const std::string& strOwnKey = request.params.size() > 4 ? request.params[4].get_str() : "";
    const CKey& ownerKey = strOwnKey.empty() ? GetKeyFromWallet(pwallet, dmn->pdmnState->keyIDOwner)
                                             : ParsePrivKey(pwallet, strOwnKey, false);

    CMutableTransaction tx;
    tx.nVersion = CTransaction::TxVersion::SAPLING;
    tx.nType = CTransaction::TxType::PROUPREG;

    // make sure fee calculation works
    pl.vchSig.resize(CPubKey::COMPACT_SIGNATURE_SIZE);
    FundSpecialTx(pwallet, tx, pl);
    SignSpecialTxPayloadByHash(tx, pl, ownerKey);

    return SignAndSendSpecialTx(pwallet, tx, pl);
}

UniValue protx_revoke(const JSONRPCRequest& request)
{
    CWallet * const pwallet = GetWalletForJSONRPCRequest(request);

    if (!EnsureWalletIsAvailable(pwallet, request.fHelp))
        return NullUniValue;

    if (request.fHelp || request.params.size() < 1 || request.params.size() > 3) {
        throw std::runtime_error(
                "protx_update_revoke \"proTxHash\" (\"operatorKey\" reason)\n"
                "\nCreates and sends a ProUpRevTx to the network. This will revoke the operator key of the masternode and\n"
                "put it into the PoSe-banned state. It will also set the service field of the masternode\n"
                "to zero. Use this in case your operator key got compromised or you want to stop providing your service\n"
                "to the masternode owner.\n"
                + HelpRequiringPassphrase(pwallet) + "\n"
                "\nArguments:\n"
                + GetHelpString(1, proTxHash)
                + GetHelpString(2, operatorKey)
                + GetHelpString(3, revocationReason) +
                "\nResult:\n"
                "\"txid\"                        (string) The transaction id.\n"
                "\nExamples:\n"
                + HelpExampleCli("protx_revoke", "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"")
                + HelpExampleCli("protx_revoke", "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\" \"\" 2")
        );
    }
    CheckEvoUpgradeEnforcement();

    EnsureWalletIsUnlocked(pwallet);
    // Make sure the results are valid at least up to the most recent block
    // the user could have gotten from another RPC command prior to now
    pwallet->BlockUntilSyncedToCurrentChain();

    ProUpRevPL pl;
    pl.nVersion = ProUpServPL::CURRENT_VERSION;
    pl.proTxHash = ParseHashV(request.params[0], "proTxHash");

    auto dmn = deterministicMNManager->GetListAtChainTip().GetMN(pl.proTxHash);
    if (!dmn) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("masternode with hash %s not found", pl.proTxHash.ToString()));
    }

    const std::string& strOpKey = request.params.size() > 1 ? request.params[1].get_str() : "";
    CKey operatorKey = GetECDSAOperatorKey(strOpKey);

    pl.nReason = ProUpRevPL::RevocationReason::REASON_NOT_SPECIFIED;
    if (request.params.size() > 2) {
        int nReason = request.params[2].get_int();
        if (nReason < 0 || nReason > ProUpRevPL::RevocationReason::REASON_LAST) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, strprintf("invalid reason %d, must be between 0 and %d",
                                                                nReason, ProUpRevPL::RevocationReason::REASON_LAST));
        }
        pl.nReason = (uint16_t)nReason;
    }

    CMutableTransaction tx;
    tx.nVersion = CTransaction::TxVersion::SAPLING;
    tx.nType = CTransaction::TxType::PROUPREV;

    FundSpecialTx(pwallet, tx, pl);
    SignSpecialTxPayloadByHash(tx, pl, operatorKey);

    return SignAndSendSpecialTx(pwallet, tx, pl);
}
#endif

UniValue generateoperatorkeypair(const JSONRPCRequest& request)
{
    if (request.fHelp || !request.params.empty()) {
        throw std::runtime_error(
                "generateoperatorkeypair\n"
                "\nReturns an ECDSA secret/public key pair for masternode operator.\n"
                "\nResult:\n"
                "{\n"
                "  \"secret\": \"xxxx\",        (string) ECDSA WIF secret key\n"
                "  \"public\": \"xxxx\",        (string) ECDSA public key (hex)\n"
                "}\n"
                "\nExamples:\n"
                + HelpExampleCli("generateoperatorkeypair", "")
                + HelpExampleRpc("generateoperatorkeypair", "")
        );
    }

    CKey key;
    key.MakeNewKey(true); // compressed
    UniValue ret(UniValue::VOBJ);
    ret.pushKV("secret", KeyIO::EncodeSecret(key));
    ret.pushKV("public", HexStr(key.GetPubKey()));
    return ret;
}

UniValue getactivemnstatus(const JSONRPCRequest& request)
{
    if (request.fHelp || !request.params.empty()) {
        throw std::runtime_error(
                "getactivemnstatus\n"
                "\nReturns the status of the active masternode manager (Multi-MN support).\n"
                "\nResult:\n"
                "{\n"
                "  \"state\": \"xxxx\",           (string) Current state (READY, WAITING_FOR_PROTX, etc.)\n"
                "  \"status\": \"xxxx\",          (string) Status message\n"
                "  \"managed_count\": n,          (numeric) Number of operator keys loaded\n"
                "  \"produce_delay\": n,          (numeric) HA failover delay in seconds (0 = primary)\n"
                "  \"masternodes\": [             (array) List of managed masternodes\n"
                "    {\n"
                "      \"proTxHash\": \"xxxx\",   (string) ProTx hash (empty if not found on-chain yet)\n"
                "      \"pubkey\": \"xxxx\",      (string) Operator public key (first 16 chars)\n"
                "      \"status\": \"xxxx\"       (string) Status (active, waiting, banned, etc.)\n"
                "    }\n"
                "  ]\n"
                "}\n"
                "\nExamples:\n"
                + HelpExampleCli("getactivemnstatus", "")
                + HelpExampleRpc("getactivemnstatus", "")
        );
    }

    if (!fMasterNode || !activeMasternodeManager) {
        throw JSONRPCError(RPC_MISC_ERROR, "This node is not configured as a masternode");
    }

    UniValue ret(UniValue::VOBJ);

    // State and status
    const char* stateStr = "UNKNOWN";
    switch (activeMasternodeManager->GetState()) {
        case CActiveDeterministicMasternodeManager::MASTERNODE_WAITING_FOR_PROTX:
            stateStr = "WAITING_FOR_PROTX"; break;
        case CActiveDeterministicMasternodeManager::MASTERNODE_POSE_BANNED:
            stateStr = "POSE_BANNED"; break;
        case CActiveDeterministicMasternodeManager::MASTERNODE_REMOVED:
            stateStr = "REMOVED"; break;
        case CActiveDeterministicMasternodeManager::MASTERNODE_OPERATOR_KEY_CHANGED:
            stateStr = "OPERATOR_KEY_CHANGED"; break;
        case CActiveDeterministicMasternodeManager::MASTERNODE_PROTX_IP_CHANGED:
            stateStr = "PROTX_IP_CHANGED"; break;
        case CActiveDeterministicMasternodeManager::MASTERNODE_READY:
            stateStr = "READY"; break;
        case CActiveDeterministicMasternodeManager::MASTERNODE_ERROR:
            stateStr = "ERROR"; break;
    }

    ret.pushKV("state", stateStr);
    ret.pushKV("status", activeMasternodeManager->GetStatus());
    ret.pushKV("managed_count", (int)activeMasternodeManager->GetManagedCount());
    ret.pushKV("produce_delay", activeMasternodeManager->GetProduceDelay());

    // MULTI-MN v4.0: List of managed MNs
    UniValue mnArray(UniValue::VARR);
    const CActiveMasternodeInfo* info = activeMasternodeManager->GetInfo();

    CDeterministicMNList mnList = deterministicMNManager->GetListAtChainTip();

    // List managed MNs (proTxHash -> pubKeyId)
    for (const auto& [proTxHash, pubKeyId] : info->managedMNs) {
        UniValue mnObj(UniValue::VOBJ);

        // Get the operator key for this MN
        CKey opKey;
        info->GetKeyByPubKeyId(pubKeyId, opKey);
        CPubKey pubKey = opKey.GetPubKey();

        mnObj.pushKV("proTxHash", proTxHash.ToString());
        mnObj.pushKV("pubkey", HexStr(pubKey).substr(0, 32) + "...");

        auto dmn = mnList.GetMN(proTxHash);
        if (!dmn) {
            mnObj.pushKV("status", "removed");
        } else if (dmn->IsPoSeBanned()) {
            mnObj.pushKV("status", "pose_banned");
        } else {
            mnObj.pushKV("status", "active");
        }

        mnArray.push_back(mnObj);
    }

    // Also show operator keys that don't have MNs yet (waiting for ProRegTx)
    for (const auto& [pubKeyId, opKey] : info->operatorKeys) {
        // Check if this key has any managed MNs
        bool hasAnyMN = false;
        for (const auto& [proTxHash, mnPubKeyId] : info->managedMNs) {
            if (mnPubKeyId == pubKeyId) {
                hasAnyMN = true;
                break;
            }
        }

        if (!hasAnyMN) {
            // This key has no MNs on-chain yet
            UniValue mnObj(UniValue::VOBJ);
            mnObj.pushKV("proTxHash", "");
            mnObj.pushKV("pubkey", HexStr(opKey.GetPubKey()).substr(0, 32) + "...");
            mnObj.pushKV("status", "waiting_for_protx");
            mnArray.push_back(mnObj);
        }
    }

    ret.pushKV("masternodes", mnArray);

    return ret;
}

// clang-format off
static const CRPCCommand commands[] =
{ //  category       name                              actor (function)         okSafe argNames
  //  -------------- --------------------------------- ------------------------ ------ --------
    { "evo",         "generateoperatorkeypair",        &generateoperatorkeypair, true, {} },
    { "evo",         "getactivemnstatus",              &getactivemnstatus,      true,  {} },
    { "evo",         "protx_list",                     &protx_list,             true,  {"detailed","wallet_only","valid_only","height"} },
#ifdef ENABLE_WALLET
    { "evo",         "protx_register",                 &protx_register,         true,  {"collateralHash","collateralIndex","ipAndPort","ownerAddress","operatorPubKey","votingAddress","payoutAddress","operatorReward","operatorPayoutAddress"} },
    { "evo",         "protx_register_fund",            &protx_register_fund,    true,  {"collateralAddress","ipAndPort","ownerAddress","operatorPubKey","votingAddress","payoutAddress","operatorReward","operatorPayoutAddress"} },
    { "evo",         "protx_register_prepare",         &protx_register_prepare, true,  {"collateralHash","collateralIndex","ipAndPort","ownerAddress","operatorPubKey","votingAddress","payoutAddress","operatorReward","operatorPayoutAddress"} },
    { "evo",         "protx_register_submit",          &protx_register_submit,  true,  {"tx","sig"} },
    { "evo",         "protx_revoke",                   &protx_revoke,           true,  {"proTxHash","operatorKey","reason"} },
    { "evo",         "protx_update_registrar",         &protx_update_registrar, true,  {"proTxHash","operatorPubKey","votingAddress","payoutAddress","ownerKey"} },
    { "evo",         "protx_update_service",           &protx_update_service,   true,  {"proTxHash","ipAndPort","operatorPayoutAddress","operatorKey"} },
    { "evo",         "protx_register_batch",           &protx_register_batch,   true,  {"ipAndPort","operatorPubKey","payoutAddress","count"} },
#endif  //ENABLE_WALLET
};
// clang-format on

void RegisterEvoRPCCommands(CRPCTable& _tableRPC)
{
    for (const auto& command : commands) {
        _tableRPC.appendCommand(command.name, &command);
    }
}
