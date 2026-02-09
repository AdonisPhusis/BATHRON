/**
 * SecretVault - Encrypted local storage for HTLC secrets
 *
 * Uses WebCrypto API for encryption and IndexedDB for persistence.
 * Secrets (S) are encrypted with a key derived from user's wallet signature.
 *
 * Security Model:
 * - Master key derived from wallet signature (proves ownership)
 * - AES-GCM encryption for secrets
 * - IndexedDB for persistence (browser-local)
 * - Secrets never leave browser unencrypted
 */

const SecretVault = {
    DB_NAME: 'kpiv_dex_vault',
    DB_VERSION: 1,
    STORE_NAME: 'secrets',

    db: null,
    masterKey: null,
    walletAddress: null,
    // Flag for non-secure context (HTTP) - secrets stored unencrypted
    insecureMode: false,

    /**
     * Initialize the vault with user's wallet
     * @param {string} walletAddress - User's Polygon address
     * @param {function} signMessage - Function to sign a message with wallet
     */
    async init(walletAddress, signMessage) {
        this.walletAddress = walletAddress.toLowerCase();

        // Check if WebCrypto is available (requires HTTPS or localhost)
        if (!window.crypto || !window.crypto.subtle) {
            console.warn('[Vault] WebCrypto not available (HTTP context). Running in INSECURE mode for testnet demo.');
            this.insecureMode = true;
        }

        // Open IndexedDB
        await this._openDB();

        // Derive master key from wallet signature (only in secure mode)
        if (!this.insecureMode) {
            await this._deriveMasterKey(signMessage);
        } else {
            // In insecure mode, just use wallet address as identifier
            this.masterKey = 'insecure-' + this.walletAddress;
            console.warn('[Vault] ⚠️ TESTNET ONLY - Secrets are NOT encrypted!');
        }

        console.log('[Vault] Initialized for', this.walletAddress.slice(0, 10) + '...');
        return true;
    },

    /**
     * Open IndexedDB database
     */
    _openDB() {
        return new Promise((resolve, reject) => {
            const request = indexedDB.open(this.DB_NAME, this.DB_VERSION);

            request.onerror = () => reject(request.error);
            request.onsuccess = () => {
                this.db = request.result;
                resolve();
            };

            request.onupgradeneeded = (event) => {
                const db = event.target.result;
                if (!db.objectStoreNames.contains(this.STORE_NAME)) {
                    const store = db.createObjectStore(this.STORE_NAME, { keyPath: 'id' });
                    store.createIndex('wallet', 'wallet', { unique: false });
                    store.createIndex('hashlock', 'hashlock', { unique: true });
                }
            };
        });
    },

    /**
     * Derive master encryption key from wallet signature
     * This proves ownership without storing the private key
     */
    async _deriveMasterKey(signMessage) {
        // Sign a deterministic message to derive the key
        const message = `KPIV DEX Vault Authentication\nWallet: ${this.walletAddress}\nPurpose: Encrypt swap secrets`;
        const signature = await signMessage(message);

        // Use signature as seed for key derivation
        const encoder = new TextEncoder();
        const signatureBytes = encoder.encode(signature);

        // Import as raw key material
        const keyMaterial = await crypto.subtle.importKey(
            'raw',
            signatureBytes.slice(0, 32), // Use first 32 bytes
            { name: 'PBKDF2' },
            false,
            ['deriveKey']
        );

        // Derive AES-GCM key
        this.masterKey = await crypto.subtle.deriveKey(
            {
                name: 'PBKDF2',
                salt: encoder.encode('KPIV-DEX-VAULT-SALT'),
                iterations: 100000,
                hash: 'SHA-256'
            },
            keyMaterial,
            { name: 'AES-GCM', length: 256 },
            false,
            ['encrypt', 'decrypt']
        );
    },

    /**
     * Generate a new random secret (S) for HTLC
     * @returns {Promise<Object>} { secret: hex, hashlock: hex }
     *
     * IMPORTANT: Uses SHA256 (NOT keccak256) for cross-chain compatibility
     * with BATHRON Core which uses single-round SHA256 for HTLC hashlocks.
     */
    async generateSecret() {
        // Generate 32 random bytes for secret
        const secretBytes = crypto.getRandomValues(new Uint8Array(32));
        const secret = this._bytesToHex(secretBytes);

        let hashlock;

        if (this.insecureMode || !crypto.subtle) {
            // Use ethers.js SHA256 (works in HTTP context)
            // ethers.sha256 expects bytes as hex with 0x prefix
            hashlock = ethers.sha256('0x' + secret).slice(2); // Remove 0x prefix
            console.log('[Vault] Using ethers.sha256 for hashlock');
        } else {
            // Calculate hashlock H = SHA256(S) using WebCrypto
            // CRITICAL: BATHRON Core uses single-round SHA256, NOT keccak256
            const hashBuffer = await crypto.subtle.digest('SHA-256', secretBytes);
            hashlock = this._bytesToHex(new Uint8Array(hashBuffer));
        }

        return {
            secret: secret,
            hashlock: hashlock
        };
    },

    /**
     * Store an encrypted secret
     * @param {string} hashlock - The hashlock (H) as identifier
     * @param {string} secret - The secret (S) to encrypt
     * @param {Object} metadata - Additional swap metadata
     */
    async storeSecret(hashlock, secret, metadata = {}) {
        if (!this.masterKey) {
            throw new Error('Vault not initialized');
        }

        let record;

        if (this.insecureMode) {
            // INSECURE MODE: Store secret in plain text (testnet only!)
            record = {
                id: hashlock,
                wallet: this.walletAddress,
                hashlock: hashlock,
                plainSecret: secret,  // NOT encrypted!
                insecure: true,
                metadata: metadata,
                createdAt: Date.now()
            };
        } else {
            // SECURE MODE: Encrypt the secret
            const iv = crypto.getRandomValues(new Uint8Array(12));
            const encoder = new TextEncoder();
            const encrypted = await crypto.subtle.encrypt(
                { name: 'AES-GCM', iv: iv },
                this.masterKey,
                encoder.encode(secret)
            );

            record = {
                id: hashlock,
                wallet: this.walletAddress,
                hashlock: hashlock,
                encryptedSecret: this._bytesToHex(new Uint8Array(encrypted)),
                iv: this._bytesToHex(iv),
                metadata: metadata,
                createdAt: Date.now()
            };
        }

        return new Promise((resolve, reject) => {
            const tx = this.db.transaction([this.STORE_NAME], 'readwrite');
            const store = tx.objectStore(this.STORE_NAME);
            const request = store.put(record);

            request.onsuccess = () => {
                console.log('[Vault] Stored secret for hashlock:', hashlock.slice(0, 16) + '...');
                resolve(true);
            };
            request.onerror = () => reject(request.error);
        });
    },

    /**
     * Retrieve and decrypt a secret
     * @param {string} hashlock - The hashlock to look up
     * @returns {Object} { secret, metadata } or null
     */
    async getSecret(hashlock) {
        if (!this.masterKey) {
            throw new Error('Vault not initialized');
        }

        const record = await this._getRecord(hashlock);
        if (!record) {
            return null;
        }

        // Check if stored in insecure mode
        if (record.insecure || record.plainSecret) {
            return {
                secret: record.plainSecret,
                metadata: record.metadata,
                createdAt: record.createdAt
            };
        }

        // Decrypt the secret (secure mode)
        const iv = this._hexToBytes(record.iv);
        const encrypted = this._hexToBytes(record.encryptedSecret);

        const decrypted = await crypto.subtle.decrypt(
            { name: 'AES-GCM', iv: iv },
            this.masterKey,
            encrypted
        );

        const decoder = new TextDecoder();
        return {
            secret: decoder.decode(decrypted),
            metadata: record.metadata,
            createdAt: record.createdAt
        };
    },

    /**
     * List all secrets for current wallet
     * @returns {Array} Array of { hashlock, metadata, createdAt }
     */
    async listSecrets() {
        return new Promise((resolve, reject) => {
            const tx = this.db.transaction([this.STORE_NAME], 'readonly');
            const store = tx.objectStore(this.STORE_NAME);
            const index = store.index('wallet');
            const request = index.getAll(this.walletAddress);

            request.onsuccess = () => {
                const results = request.result.map(r => ({
                    hashlock: r.hashlock,
                    metadata: r.metadata,
                    createdAt: r.createdAt
                }));
                resolve(results);
            };
            request.onerror = () => reject(request.error);
        });
    },

    /**
     * Delete a secret (after successful claim)
     * @param {string} hashlock - The hashlock to delete
     */
    async deleteSecret(hashlock) {
        return new Promise((resolve, reject) => {
            const tx = this.db.transaction([this.STORE_NAME], 'readwrite');
            const store = tx.objectStore(this.STORE_NAME);
            const request = store.delete(hashlock);

            request.onsuccess = () => {
                console.log('[Vault] Deleted secret for hashlock:', hashlock.slice(0, 16) + '...');
                resolve(true);
            };
            request.onerror = () => reject(request.error);
        });
    },

    /**
     * Get a record from IndexedDB
     */
    _getRecord(hashlock) {
        return new Promise((resolve, reject) => {
            const tx = this.db.transaction([this.STORE_NAME], 'readonly');
            const store = tx.objectStore(this.STORE_NAME);
            const request = store.get(hashlock);

            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
        });
    },

    /**
     * Convert bytes to hex string
     */
    _bytesToHex(bytes) {
        return Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
    },

    /**
     * Convert hex string to bytes
     */
    _hexToBytes(hex) {
        const bytes = new Uint8Array(hex.length / 2);
        for (let i = 0; i < hex.length; i += 2) {
            bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
        }
        return bytes;
    },

    /**
     * Check if vault is ready
     */
    isReady() {
        return this.db !== null && this.masterKey !== null;
    },

    /**
     * Clear all data (for testing)
     */
    async clearAll() {
        return new Promise((resolve, reject) => {
            const tx = this.db.transaction([this.STORE_NAME], 'readwrite');
            const store = tx.objectStore(this.STORE_NAME);
            const request = store.clear();

            request.onsuccess = () => resolve(true);
            request.onerror = () => reject(request.error);
        });
    }
};

// Export for use in other modules
window.SecretVault = SecretVault;
