import { Bytes } from "@graphprotocol/graph-ts"
import {
  ProtocolPaused,
  ProtocolUnpaused,
} from "../../generated/EmergencyPause/EmergencyPause"
import { ProtocolEvent } from "../../generated/schema"

export function handleProtocolPaused(event: ProtocolPaused): void {
  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let pe = new ProtocolEvent(id)
  pe.eventType = "PAUSED"
  pe.actor = event.params.param0
  pe.productId = null
  pe.timestamp = event.block.timestamp
  pe.tx = event.transaction.hash
  pe.save()
}

export function handleProtocolUnpaused(event: ProtocolUnpaused): void {
  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let pe = new ProtocolEvent(id)
  pe.eventType = "UNPAUSED"
  pe.actor = event.params.param0
  pe.productId = null
  pe.timestamp = event.block.timestamp
  pe.tx = event.transaction.hash
  pe.save()
}
