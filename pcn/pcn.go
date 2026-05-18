package pcn

import (
	"blockEmulator/message"
	"blockEmulator/params"
	"fmt"
)

type Bridges struct {
	BridgeRawMegs  map[string]*message.BridgeRawMeg
	ChainConfig    *params.ChainConfig
	Addrs          []string
	RawTx2BridgeTx map[string][]string
}

func NewBridgeAddresses(shardNum int) []string {
	addrs := make([]string, shardNum)
	for sid := 0; sid < shardNum; sid++ {
		addrs[sid] = fmt.Sprintf("%040x", sid)
	}
	return addrs
}

func (b *Bridges) IsBridgeAccount(address string) bool {
	for _, bridgeAddress := range b.Addrs {
		if bridgeAddress == address {
			return true
		}
	}
	return false
}

func (b *Bridges) NewBridges(pcc *params.ChainConfig, bridgeAddrs []string) {
	b.BridgeRawMegs = make(map[string]*message.BridgeRawMeg)
	b.RawTx2BridgeTx = make(map[string][]string)
	b.ChainConfig = pcc
	b.Addrs = bridgeAddrs
}
