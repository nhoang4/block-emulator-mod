package pbft_all

import (
	"blockEmulator/message"
	"blockEmulator/networks"
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

	if rbom.forwardToBridgeLeader(message.CSeqIDinfo, content, "Bridge SeqIDinfo", sii.SenderShardID, len(sii.Tx2s)) {
		return
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
	if rbom.forwardToBridgeLeader(message.CInject, content, "injected Bridge txs", it.ToShardID, len(it.Txs)) {
		return
	}
	rbom.pbftNode.CurChain.Txpool.AddTxs2Pool(it.Txs)
	rbom.pbftNode.pl.Plog.Printf("S%dN%d : has handled injected Bridge txs msg, txs: %d \n", rbom.pbftNode.ShardID, rbom.pbftNode.NodeID, len(it.Txs))
}

func (rbom *RawBridgeOutsideModule) forwardToBridgeLeader(msgType message.MessageType, content []byte, label string, source uint64, txCount int) bool {
	leaderID := uint64(rbom.pbftNode.view.Load())
	if leaderID == rbom.pbftNode.NodeID {
		return false
	}
	shardNodes, ok := rbom.pbftNode.ip_nodeTable[rbom.pbftNode.ShardID]
	if !ok {
		return false
	}
	leaderAddr, ok := shardNodes[leaderID]
	if !ok || leaderAddr == "" {
		return false
	}
	msgSend := message.MergeMessage(msgType, content)
	if err := networks.TcpDialSync(msgSend, leaderAddr, bridgeForwardSendAttempts); err != nil {
		rbom.pbftNode.pl.Plog.Printf("S%dN%d : failed to redirect %s from %d to leader node %d after %d attempts: %v\n",
			rbom.pbftNode.ShardID, rbom.pbftNode.NodeID, label, source, leaderID, bridgeForwardSendAttempts, err)
		return false
	}
	rbom.pbftNode.pl.Plog.Printf("S%dN%d : redirected %s from %d to leader node %d, txs %d\n",
		rbom.pbftNode.ShardID, rbom.pbftNode.NodeID, label, source, leaderID, txCount)
	return true
}
