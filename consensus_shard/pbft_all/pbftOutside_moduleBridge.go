package pbft_all

import (
	"blockEmulator/message"
	"encoding/json"
	"log"
	"math/big"
)

type RawBridgeOutsideModule struct {
	pbftNode *PbftConsensusNode
}

func (rbom *RawBridgeOutsideModule) HandleMessageOutsidePBFT(msgType message.MessageType, content []byte) bool {
	switch msgType {
	case message.CSeqIDinfo:
		rbom.handleSeqIDinfos(content)
	case message.CInject:
		rbom.handleInjectTx(content)
	case message.CBridgeOverlay:
		rbom.handleBridgeOverlay(content)
	default:
	}
	return true
}

func (rbom *RawBridgeOutsideModule) handleBridgeOverlay(content []byte) {
	overlay := new(message.BridgeOverlayMsg)
	err := json.Unmarshal(content, overlay)
	if err != nil {
		log.Panic(err)
	}

	rbom.pbftNode.bridgeOverlayLock.Lock()
	rbom.pbftNode.bridgeOverlayEpoch = overlay.Epoch
	rbom.pbftNode.bridgeDegreeLimits = append([]int(nil), overlay.DegreeLimits...)
	rbom.pbftNode.bridgeOverlayEdges = append([][2]uint64(nil), overlay.Edges...)
	rbom.pbftNode.bridgeOverlayRoutes = overlay.Routes
	rbom.pbftNode.bridgeOverlayLock.Unlock()

	rbom.pbftNode.pl.Plog.Printf("S%dN%d : installed Bridge overlay epoch %d, edges %d\n", rbom.pbftNode.ShardID, rbom.pbftNode.NodeID, overlay.Epoch, len(overlay.Edges))
}

func (rbom *RawBridgeOutsideModule) handleSeqIDinfos(content []byte) {
	sii := new(message.SeqIDinfo)
	err := json.Unmarshal(content, sii)
	if err != nil {
		log.Panic(err)
	}

	if sii.Values != nil {
		if val, ok := sii.Values[rbom.pbftNode.ShardID]; ok && val != nil {
			if _, exists := rbom.pbftNode.bridgeBalances[sii.SenderShardID]; !exists {
				rbom.pbftNode.bridgeBalances[sii.SenderShardID] = new(big.Int)
			}
			rbom.pbftNode.bridgeBalances[sii.SenderShardID].Add(rbom.pbftNode.bridgeBalances[sii.SenderShardID], val)
		}
	}

	if len(sii.Tx2s) > 0 {
		rbom.pbftNode.CurChain.Txpool.AddTxs2Pool(sii.Tx2s)
	}

	rbom.pbftNode.seqMapLock.Lock()
	rbom.pbftNode.seqIDMap[sii.SenderShardID] = sii.SenderSeq
	rbom.pbftNode.seqMapLock.Unlock()
	rbom.pbftNode.pl.Plog.Printf("S%dN%d : has handled Bridge SeqIDinfo from shard %d, seq %d, tx2s %d\n", rbom.pbftNode.ShardID, rbom.pbftNode.NodeID, sii.SenderShardID, sii.SenderSeq, len(sii.Tx2s))
}

func (rbom *RawBridgeOutsideModule) handleInjectTx(content []byte) {
	it := new(message.InjectTxs)
	err := json.Unmarshal(content, it)
	if err != nil {
		log.Panic(err)
	}
	rbom.pbftNode.CurChain.Txpool.AddTxs2Pool(it.Txs)
	rbom.pbftNode.pl.Plog.Printf("S%dN%d : has handled injected Bridge txs msg, txs: %d \n", rbom.pbftNode.ShardID, rbom.pbftNode.NodeID, len(it.Txs))
}
