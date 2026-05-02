import { BaseHandler, Version } from "../../BaseHandler"
import { LiquidationDetail } from "../../../../generated/schema"
import { ethereum } from "@graphprotocol/graph-ts"

export class TakeoverPartyALiquidationHandler<T> extends BaseHandler {
	handleQuote(_event: ethereum.Event, version: Version): void {
		// @ts-ignore
		const event = changetype<T>(_event)
		let entityId =
			event.params.partyA.toHexString() +
			"-" +
			event.params.liquidationId.toHexString() +
			"-" +
			event.address.toHexString()
		let entity = LiquidationDetail.load(entityId)
		if (!entity) return
		entity.disputed = false
		entity.save()
	}
}
