# API Key Security Notes

## Storage
- API keys are hashed with SHA-256 + random salt
- Raw keys are shown once at creation and never stored
- In-memory storage for MVP — migrate to encrypted DB for production

## Rate Limiting
- Max 5 purchases per minute per wallet
- Max 3 API keys per wallet

## Nonce System
- Only 1 transaction processed at a time per wallet (queue)
- Prevents double-spend from concurrent requests

## Relayer Wallet
- Keep balance low (~$50 ETH for gas)
- Separate from oracle signer key
- Monitor balance with alerts

## User Approve
- Recommend limited approve ($10,000) not infinite
- Users can revoke approve anytime via wallet
