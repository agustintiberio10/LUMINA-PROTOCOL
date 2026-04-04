import { BigInt, Bytes } from "@graphprotocol/graph-ts"
import {
  PolicyPurchased,
  PayoutTriggered,
  PolicyCleanedUp,
} from "../../generated/CoverRouter/CoverRouter"
import { Policy, Claim, Shield } from "../../generated/schema"

export function handlePolicyPurchased(event: PolicyPurchased): void {
  let policyId = event.params.param0 // policyId
  let productId = event.params.param1 // productId (bytes32)
  let buyer = event.params.param2 // buyer address
  let vault = event.params.param3 // vault address
  let coverageAmount = event.params.param4
  let premiumPaid = event.params.param5
  let durationSeconds = event.params.param6

  let id = productId.toHexString() + "-" + policyId.toString()
  let policy = new Policy(id)
  policy.policyId = policyId
  policy.productId = productId
  policy.buyer = buyer
  policy.vault = vault
  policy.coverageAmount = coverageAmount
  policy.premiumPaid = premiumPaid
  policy.durationSeconds = durationSeconds.toI32()
  policy.startsAt = event.block.timestamp
  policy.expiresAt = event.block.timestamp.plus(BigInt.fromI32(durationSeconds.toI32()))
  policy.resolved = false
  policy.createdAt = event.block.timestamp
  policy.createdTx = event.transaction.hash

  // Create or load Shield entity
  // We don't have the shield address in the event, so we use productId as shield ID
  let shieldId = productId.toHexString()
  let shield = Shield.load(shieldId)
  if (!shield) {
    shield = new Shield(shieldId)
    shield.address = Bytes.empty()
    shield.totalPolicies = BigInt.fromI32(0)
  }
  shield.totalPolicies = shield.totalPolicies.plus(BigInt.fromI32(1))
  shield.save()

  policy.shield = shieldId
  policy.save()
}

export function handlePayoutTriggered(event: PayoutTriggered): void {
  let policyId = event.params.param0
  let productId = event.params.param1
  let recipient = event.params.param2
  let payoutAmount = event.params.param3

  let claimId = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let claim = new Claim(claimId)
  claim.policyId = policyId
  claim.productId = productId
  claim.recipient = recipient
  claim.payoutAmount = payoutAmount
  claim.timestamp = event.block.timestamp
  claim.tx = event.transaction.hash
  claim.save()

  // Mark policy as resolved
  let id = productId.toHexString() + "-" + policyId.toString()
  let policy = Policy.load(id)
  if (policy) {
    policy.resolved = true
    policy.save()
  }
}

export function handlePolicyCleanedUp(event: PolicyCleanedUp): void {
  let policyId = event.params.param0
  let productId = event.params.param1

  let id = productId.toHexString() + "-" + policyId.toString()
  let policy = Policy.load(id)
  if (policy) {
    policy.resolved = true
    policy.save()
  }
}
