import { BigInt, Bytes } from "@graphprotocol/graph-ts"
import {
  AllocationRecorded,
  AllocationReleased,
  ProductFreezeChanged,
} from "../../generated/PolicyManager/PolicyManager"
import { ProtocolEvent } from "../../generated/schema"

export function handleAllocationRecorded(event: AllocationRecorded): void {
  // Allocation tracking is already handled in CoverRouter handler
  // This event confirms the vault assignment
}

export function handleAllocationReleased(event: AllocationReleased): void {
  // Release tracking — policy cleanup/payout already handled in CoverRouter
}

export function handleProductFreezeChanged(event: ProductFreezeChanged): void {
  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let pe = new ProtocolEvent(id)
  pe.eventType = event.params.param1 ? "PRODUCT_FROZEN" : "PRODUCT_UNFROZEN"
  pe.actor = event.transaction.from
  pe.productId = event.params.param0
  pe.timestamp = event.block.timestamp
  pe.tx = event.transaction.hash
  pe.save()
}
