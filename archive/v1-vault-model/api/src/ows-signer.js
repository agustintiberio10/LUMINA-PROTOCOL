// api/src/ows-signer.js
// OWS (Open Wallet Standard) integration for Lumina Protocol
// Replaces raw private key signing with policy-gated OWS signing
// Falls back to ethers if OWS is not available (Windows, missing config, etc.)

let ows = null;
let owsAvailable = false;

// Try to load OWS - falls back to ethers if not available
try {
  ows = require('@open-wallet-standard/core');
  owsAvailable = true;
  console.log('[OWS] Open Wallet Standard loaded successfully');
} catch (e) {
  console.warn('[OWS] Not available - falling back to ethers signing:', e.message);
}

const WALLET_NAME = process.env.OWS_WALLET_NAME || 'lumina-relayer';
const OWS_TOKEN = process.env.OWS_TOKEN; // ows_key_xxx

// Initialize OWS wallet (called once at startup)
async function initOWS() {
  if (!owsAvailable) {
    console.log('[OWS] Skipped - using ethers fallback');
    return false;
  }

  try {
    const wallets = await ows.listWallets();
    const exists = wallets.some(w => w.name === WALLET_NAME);

    if (!exists) {
      console.log(`[OWS] Wallet "${WALLET_NAME}" not found. Run setup first.`);
      return false;
    }

    console.log(`[OWS] Wallet "${WALLET_NAME}" ready`);
    console.log(`[OWS] Token configured: ${OWS_TOKEN ? 'yes' : 'no (using passphrase mode)'}`);
    return true;
  } catch (e) {
    console.error('[OWS] Init failed:', e.message);
    return false;
  }
}

// Sign an EIP-712 typed data (for purchase quotes)
async function signTypedData(domain, types, value) {
  if (!owsAvailable || !OWS_TOKEN) return null;

  try {
    const result = await ows.signTypedData(
      WALLET_NAME,
      'evm',
      { domain, types, value },
      OWS_TOKEN
    );
    console.log('[OWS] signTypedData success');
    return result.signature;
  } catch (e) {
    if (e.code === 'POLICY_DENIED') {
      console.error('[OWS] POLICY DENIED:', e.reason);
      throw new Error(`OWS Policy denied: ${e.reason}`);
    }
    console.error('[OWS] signTypedData failed:', e.message);
    return null;
  }
}

// Sign a message (for oracle proofs)
async function signMessage(message) {
  if (!owsAvailable || !OWS_TOKEN) return null;

  try {
    const result = await ows.signMessage(
      WALLET_NAME,
      'evm',
      message,
      OWS_TOKEN
    );
    console.log('[OWS] signMessage success');
    return result.signature;
  } catch (e) {
    if (e.code === 'POLICY_DENIED') {
      console.error('[OWS] POLICY DENIED:', e.reason);
      throw new Error(`OWS Policy denied: ${e.reason}`);
    }
    console.error('[OWS] signMessage failed:', e.message);
    return null;
  }
}

// Sign a raw transaction (for on-chain operations)
async function signTransaction(txHex) {
  if (!owsAvailable || !OWS_TOKEN) return null;

  try {
    const result = await ows.signTransaction(
      WALLET_NAME,
      'evm',
      txHex,
      OWS_TOKEN
    );
    console.log('[OWS] signTransaction success');
    return result.signature;
  } catch (e) {
    if (e.code === 'POLICY_DENIED') {
      console.error('[OWS] POLICY DENIED:', e.reason);
      throw new Error(`OWS Policy denied: ${e.reason}`);
    }
    console.error('[OWS] signTransaction failed:', e.message);
    return null;
  }
}

// Get the wallet address
async function getAddress() {
  if (!owsAvailable) return null;

  try {
    const wallets = await ows.listWallets();
    const wallet = wallets.find(w => w.name === WALLET_NAME);
    if (!wallet) return null;

    const evmAccount = wallet.accounts.find(a => a.chain.startsWith('eip155:'));
    return evmAccount ? evmAccount.address : null;
  } catch (e) {
    return null;
  }
}

// Health check
function isAvailable() {
  return owsAvailable && !!OWS_TOKEN;
}

module.exports = {
  initOWS,
  signTypedData,
  signMessage,
  signTransaction,
  getAddress,
  isAvailable,
};
