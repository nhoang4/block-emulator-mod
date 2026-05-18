package committee

import "blockEmulator/message"

type CommitteeModule interface {
	HandleBlockInfo(*message.BlockInfoMsg)
	MsgSendingControl()
	HandleOtherMessage([]byte)
}

type DrainableCommitteeModule interface {
	ExecutionDrained() bool
	DrainStatus() string
}
