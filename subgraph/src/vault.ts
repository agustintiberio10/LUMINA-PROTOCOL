import { BigInt, Bytes } from "@graphprotocol/graph-ts"
import {
  Deposited,
  WithdrawalCompleted,
  WithdrawalRequested,
} from "../../generated/VolatileShortVault/BaseVault"
import { Vault, Deposit, Withdrawal, CooldownRequest } from "../../generated/schema"

function getOrCreateVault(address: Bytes): Vault {
  let id = address.toHexString()
  let vault = Vault.load(id)
  if (!vault) {
    vault = new Vault(id)
    vault.address = address
    vault.totalDeposits = BigInt.fromI32(0)
    vault.totalWithdrawals = BigInt.fromI32(0)
    vault.save()
  }
  return vault
}

export function handleDeposited(event: Deposited): void {
  let vaultAddress = event.address
  let vault = getOrCreateVault(vaultAddress)
  vault.totalDeposits = vault.totalDeposits.plus(event.params.param1) // assets
  vault.save()

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let deposit = new Deposit(id)
  deposit.vault = vault.id
  deposit.depositor = event.params.param0
  deposit.assets = event.params.param1
  deposit.shares = event.params.param2
  deposit.timestamp = event.block.timestamp
  deposit.tx = event.transaction.hash
  deposit.save()
}

export function handleWithdrawalCompleted(event: WithdrawalCompleted): void {
  let vaultAddress = event.address
  let vault = getOrCreateVault(vaultAddress)
  vault.totalWithdrawals = vault.totalWithdrawals.plus(event.params.param1) // assets
  vault.save()

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let withdrawal = new Withdrawal(id)
  withdrawal.vault = vault.id
  withdrawal.user = event.params.param0
  withdrawal.assets = event.params.param1
  withdrawal.shares = event.params.param2
  withdrawal.timestamp = event.block.timestamp
  withdrawal.tx = event.transaction.hash
  withdrawal.save()
}

export function handleWithdrawalRequested(event: WithdrawalRequested): void {
  let vaultAddress = event.address
  let vault = getOrCreateVault(vaultAddress)

  let id = vaultAddress.toHexString() + "-" + event.params.param0.toHexString()
  let req = new CooldownRequest(id)
  req.vault = vault.id
  req.user = event.params.param0
  req.shares = event.params.param1
  req.cooldownEnd = event.params.param2
  req.timestamp = event.block.timestamp
  req.save()
}
