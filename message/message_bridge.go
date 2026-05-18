package message

import (
	"blockEmulator/core"
	"blockEmulator/utils"
)

var (
	BridgeRawTx    MessageType = "BridgeRawTx"
	BridgeConfirm1 MessageType = "BridgeConfirm1"
	BridgeConfirm2 MessageType = "BridgeConfirm2"
	BridgeType1    MessageType = "BridgeType1"
	BridgeType2    MessageType = "BridgeType2"

	CInjectBridge MessageType = "InjectTx_Bridge"

	CBridgeTxMap MessageType = "BridgeTxMap"
)

type BridgeRawMeg struct {
	Tx                 *core.Transaction
	ShardID            int
	Hlock              uint64
	Snonce             uint64
	Bnonce             uint64
	Signature          []byte
	Route              []uint64
	BridgeOverlayEpoch int
}

type BridgeType1Meg struct {
	RawMeg   *BridgeRawMeg
	Hcurrent uint64
	ShardID  int
}

type BridgeMag1Confirm struct {
	Tx1Hash []byte
	RawMeg  *BridgeRawMeg
}

type BridgeType2Meg struct {
	RawMeg *BridgeRawMeg
	Bridge utils.Address
}

type BridgeMag2Confirm struct {
	Tx2Hash []byte
	RawMeg  *BridgeRawMeg
}

type BridgeTxMap struct {
	BridgeTx2Bridge12 map[string][]string
}
