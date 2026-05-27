package pbft_all

import (
	"blockEmulator/core"
	"blockEmulator/message"
	"blockEmulator/networks"
	"blockEmulator/params"
	"blockEmulator/utils"
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"strconv"
	"sync"
	"time"
)

const bridgeForwardSendAttempts = 30

type RawBridgePbftExtraHandleMod struct {
	pbftNode *PbftConsensusNode
}

func (rbhm *RawBridgePbftExtraHandleMod) HandleinPropose() (bool, *message.Request) {
	rbhm.pbftNode.resetBridgeSignatureRound()
	block := rbhm.pbftNode.CurChain.GenerateBlock(int32(rbhm.pbftNode.NodeID))
	r := &message.Request{
		RequestType: message.BlockRequest,
		ReqTime:     time.Now(),
	}
	r.Msg.Content = block.Encode()
	rbhm.pbftNode.prepareBridgeHash(r.Msg.Content)
	return true, r
}

func (rbhm *RawBridgePbftExtraHandleMod) HandleinPrePrepare(ppmsg *message.PrePrepare) bool {
	if rbhm.pbftNode.CurChain.IsValidBlock(core.DecodeB(ppmsg.RequestMsg.Msg.Content)) != nil {
		rbhm.pbftNode.pl.Plog.Printf("S%dN%d : not a valid bridge block\n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID)
		return false
	}
	rbhm.pbftNode.resetBridgeSignatureRound()
	rbhm.pbftNode.prepareBridgeHash(ppmsg.RequestMsg.Msg.Content)
	if len(ppmsg.B) > 0 && !bytes.Equal(ppmsg.B, rbhm.pbftNode.bridgePreparedHash) {
		rbhm.pbftNode.pl.Plog.Printf("S%dN%d : bridge block hash mismatch\n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID)
		return false
	}
	if len(ppmsg.BlockBPKCS1) > 0 && !bytes.Equal(ppmsg.BlockBPKCS1, rbhm.pbftNode.bridgePreparedPKCS1) {
		rbhm.pbftNode.pl.Plog.Printf("S%dN%d : bridge PKCS1 block hash mismatch\n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID)
		return false
	}
	rbhm.pbftNode.requestPool[string(ppmsg.Digest)] = ppmsg.RequestMsg
	return true
}

func (rbhm *RawBridgePbftExtraHandleMod) HandleinPrepare(pmsg *message.Prepare) bool {
	if !rbhm.pbftNode.prepareBridgeHashForDigest(pmsg.Digest) {
		return false
	}
	return rbhm.pbftNode.partialSignBridge()
}

func (rbhm *RawBridgePbftExtraHandleMod) HandleinCommit(cmsg *message.Commit) bool {
	r := rbhm.pbftNode.requestPool[string(cmsg.Digest)]
	block := core.DecodeB(r.Msg.Content)
	rbhm.pbftNode.pl.Plog.Printf("S%dN%d : adding the bridge block %d...now height = %d \n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID, block.Header.Number, rbhm.pbftNode.CurChain.CurrentBlock.Header.Number)
	rbhm.pbftNode.CurChain.AddBlock(block)
	rbhm.pbftNode.CurChain.Txpool.RemoveTxs(block.Body)
	rbhm.pbftNode.pl.Plog.Printf("S%dN%d : added the bridge block %d... \n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID, block.Header.Number)

	if rbhm.pbftNode.NodeID == uint64(rbhm.pbftNode.view.Load()) {
		return rbhm.handleBridgeLeaderCommit(r, block)
	}
	return true
}

func (rbhm *RawBridgePbftExtraHandleMod) handleBridgeLeaderCommit(r *message.Request, block *core.Block) bool {
	txExecuted := make([]*core.Transaction, 0)
	bridge1Txs := make([]*core.Transaction, 0)
	bridge2Txs := make([]*core.Transaction, 0)
	bridgeForwardTxs := make([]*core.Transaction, 0)
	tx2sSend := make(map[uint64][]*core.Transaction)
	outgoingValues := make(map[uint64]*big.Int, params.ShardNum)
	for sid := uint64(0); sid < uint64(params.ShardNum); sid++ {
		outgoingValues[sid] = big.NewInt(0)
	}

	for _, tx := range block.Body {
		isInnerShardTx := tx.RawTxHash == nil
		isBridge1Tx := !isInnerShardTx && tx.Sender == tx.OriginalSender
		isBridge2Tx := !isInnerShardTx && tx.Recipient == tx.FinalRecipient
		isBridgeForwardTx := !isInnerShardTx && tx.HasBridge && !isBridge1Tx && !isBridge2Tx

		switch {
		case isBridge2Tx:
			bridge2Txs = append(bridge2Txs, tx)
		case isBridge1Tx:
			nextSID, ok := rbhm.nextBridgeHop(tx)
			if !ok {
				rbhm.pbftNode.pl.Plog.Printf("S%dN%d : bridge route is invalid for bridge1 tx %x\n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID, tx.TxHash)
				continue
			}
			if rbhm.bridgeHasCapacity(nextSID, tx.Value) {
				bridge1Txs = append(bridge1Txs, tx)
				rbhm.generateNextBridgeTx(tx, tx2sSend)
				rbhm.pbftNode.bridgeBalances[nextSID].Sub(rbhm.pbftNode.bridgeBalances[nextSID], tx.Value)
				outgoingValues[nextSID].Add(outgoingValues[nextSID], tx.Value)
			} else {
				rbhm.pbftNode.pl.Plog.Printf("S%dN%d : bridge capacity to shard %d is insufficient for tx %x\n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID, nextSID, tx.TxHash)
			}
		case isBridgeForwardTx:
			nextSID, ok := rbhm.nextBridgeHop(tx)
			if !ok {
				rbhm.pbftNode.pl.Plog.Printf("S%dN%d : bridge route is invalid for forward tx %x\n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID, tx.TxHash)
				continue
			}
			if rbhm.bridgeHasCapacity(nextSID, tx.Value) {
				bridgeForwardTxs = append(bridgeForwardTxs, tx)
				rbhm.generateNextBridgeTx(tx, tx2sSend)
				rbhm.pbftNode.bridgeBalances[nextSID].Sub(rbhm.pbftNode.bridgeBalances[nextSID], tx.Value)
				outgoingValues[nextSID].Add(outgoingValues[nextSID], tx.Value)
			} else {
				rbhm.pbftNode.pl.Plog.Printf("S%dN%d : bridge capacity to shard %d is insufficient for forward tx %x\n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID, nextSID, tx.TxHash)
			}
		default:
			txExecuted = append(txExecuted, tx)
		}
	}

	if !rbhm.pbftNode.combineBridgeSignature() || !rbhm.pbftNode.verifyBridgeSignature() {
		return false
	}

	for sid, tx2s := range tx2sSend {
		if sid == rbhm.pbftNode.ShardID || len(tx2s) == 0 {
			continue
		}
		values := map[uint64]*big.Int{
			sid: new(big.Int).Set(outgoingValues[sid]),
		}
		sii := message.SeqIDinfo{
			Tx2s:          tx2s,
			SenderShardID: rbhm.pbftNode.ShardID,
			SenderSeq:     rbhm.pbftNode.sequenceID,
			Values:        values,
			JointSig:      rbhm.pbftNode.bridgeJointSig,
			SenderNode:    rbhm.pbftNode.RunningNode,
		}
		sByte, err := json.Marshal(sii)
		if err != nil {
			log.Panic()
		}
		msgSend := message.MergeMessage(message.CSeqIDinfo, sByte)
		var wg sync.WaitGroup
		for nid, addr := range rbhm.pbftNode.ip_nodeTable[sid] {
			wg.Add(1)
			go func(nid uint64, addr string) {
				defer wg.Done()
				if err := networks.TcpDialSync(msgSend, addr, bridgeForwardSendAttempts); err != nil {
					rbhm.pbftNode.pl.Plog.Printf("S%dN%d : failed to forward %d bridge txs to shard %d node %d after %d attempts: %v\n",
						rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID, len(tx2s), sid, nid, bridgeForwardSendAttempts, err)
				}
			}(nid, addr)
		}
		wg.Wait()
	}

	bim := message.BlockInfoMsg{
		BlockBodyLength:  len(block.Body),
		InnerShardTxs:    txExecuted,
		Bridge1Txs:       bridge1Txs,
		Bridge2Txs:       bridge2Txs,
		BridgeForwardTxs: bridgeForwardTxs,
		Broker1Txs:       bridge1Txs,
		Broker2Txs:       bridge2Txs,
		Epoch:            0,
		SenderShardID:    rbhm.pbftNode.ShardID,
		ProposeTime:      r.ReqTime,
		CommitTime:       time.Now(),
		JointSig:         rbhm.pbftNode.bridgeJointSig,
	}
	bByte, err := json.Marshal(bim)
	if err != nil {
		log.Panic()
	}
	msgSend := message.MergeMessage(message.CBlockInfo, bByte)
	go networks.TcpDial(msgSend, rbhm.pbftNode.ip_nodeTable[params.SupervisorShard][0])

	rbhm.pbftNode.CurChain.Txpool.GetLocked()
	metricName := []string{
		"Block Height",
		"EpochID of this block",
		"TxPool Size",
		"# of all Txs in this block",
		"# of Bridge1 Txs in this block",
		"# of BridgeForward Txs in this block",
		"# of Bridge2 Txs in this block",
		"TimeStamp - Propose (unixMill)",
		"TimeStamp - Commit (unixMill)",
		"SUM of confirm latency (ms, All Txs)",
		"SUM of confirm latency (ms, Bridge1 Txs) (Duration: Bridge1 proposed -> Bridge1 Commit)",
		"SUM of confirm latency (ms, Bridge2 Txs) (Duration: Bridge1 proposed -> Bridge2 Commit)",
	}
	metricVal := []string{
		strconv.Itoa(int(block.Header.Number)),
		strconv.Itoa(bim.Epoch),
		strconv.Itoa(len(rbhm.pbftNode.CurChain.Txpool.TxQueue)),
		strconv.Itoa(len(block.Body)),
		strconv.Itoa(len(bridge1Txs)),
		strconv.Itoa(len(bridgeForwardTxs)),
		strconv.Itoa(len(bridge2Txs)),
		strconv.FormatInt(bim.ProposeTime.UnixMilli(), 10),
		strconv.FormatInt(bim.CommitTime.UnixMilli(), 10),
		strconv.FormatInt(computeTCL(block.Body, bim.CommitTime), 10),
		strconv.FormatInt(computeTCL(bridge1Txs, bim.CommitTime), 10),
		strconv.FormatInt(computeTCL(bridge2Txs, bim.CommitTime), 10),
	}
	rbhm.pbftNode.writeCSVline(metricName, metricVal)
	rbhm.pbftNode.CurChain.Txpool.GetUnlocked()
	return true
}

func (rbhm *RawBridgePbftExtraHandleMod) bridgeHasCapacity(destSID uint64, value *big.Int) bool {
	if _, ok := rbhm.pbftNode.bridgeBalances[destSID]; !ok {
		rbhm.pbftNode.bridgeBalances[destSID] = new(big.Int).Set(params.Init_Balance)
	}
	return rbhm.pbftNode.bridgeBalances[destSID].Cmp(value) >= 0
}

func (rbhm *RawBridgePbftExtraHandleMod) generateNextBridgeTx(bridgeTx *core.Transaction, tx2sSend map[uint64][]*core.Transaction) {
	route := rbhm.bridgeRoute(bridgeTx)
	currentIdx := rbhm.currentRouteIndex(bridgeTx, route)
	if currentIdx < 0 {
		return
	}
	nextIdx := currentIdx + 1
	if nextIdx >= len(route) {
		return
	}

	nextSID := route[nextIdx]
	sender := rbhm.pbftNode.bridges.Addrs[nextSID]
	recipient := bridgeTx.FinalRecipient
	if nextIdx < len(route)-1 {
		recipient = rbhm.pbftNode.bridges.Addrs[route[nextIdx+1]]
	}

	tx2 := core.NewTransaction(sender, recipient, bridgeTx.Value, bridgeTx.Nonce, time.Now())
	tx2.HasBridge = true
	tx2.SenderIsBridge = true
	tx2.OriginalSender = bridgeTx.OriginalSender
	tx2.FinalRecipient = bridgeTx.FinalRecipient
	tx2.RawTxHash = make([]byte, len(bridgeTx.RawTxHash))
	copy(tx2.RawTxHash, bridgeTx.RawTxHash)
	tx2.BridgeRoute = append([]uint64(nil), route...)
	tx2.BridgeRouteIndex = nextIdx
	tx2.BridgeOverlayEpoch = bridgeTx.BridgeOverlayEpoch
	tx2sSend[nextSID] = append(tx2sSend[nextSID], tx2)
}

func (rbhm *RawBridgePbftExtraHandleMod) nextBridgeHop(bridgeTx *core.Transaction) (uint64, bool) {
	route := rbhm.bridgeRoute(bridgeTx)
	currentIdx := rbhm.currentRouteIndex(bridgeTx, route)
	if currentIdx < 0 || currentIdx+1 >= len(route) {
		return 0, false
	}
	return route[currentIdx+1], true
}

func (rbhm *RawBridgePbftExtraHandleMod) bridgeRoute(bridgeTx *core.Transaction) []uint64 {
	if len(bridgeTx.BridgeRoute) >= 2 {
		route := append([]uint64(nil), bridgeTx.BridgeRoute...)
		return route
	}
	sourceSID := uint64(utils.Addr2Shard(bridgeTx.OriginalSender))
	destSID := uint64(utils.Addr2Shard(bridgeTx.FinalRecipient))
	return []uint64{sourceSID, destSID}
}

func (rbhm *RawBridgePbftExtraHandleMod) currentRouteIndex(bridgeTx *core.Transaction, route []uint64) int {
	if len(route) == 0 {
		return -1
	}
	idx := bridgeTx.BridgeRouteIndex
	if idx >= 0 && idx < len(route) && route[idx] == rbhm.pbftNode.ShardID {
		return idx
	}
	for i, sid := range route {
		if sid == rbhm.pbftNode.ShardID {
			return i
		}
	}
	return -1
}

func (rbhm *RawBridgePbftExtraHandleMod) fetchModifiedMap(key string) uint64 {
	return uint64(utils.Addr2Shard(key))
}

func (rbhm *RawBridgePbftExtraHandleMod) HandleReqestforOldSeq(*message.RequestOldMessage) bool {
	fmt.Println("No operations are performed in Bridge extra handle mod")
	return true
}

func (rbhm *RawBridgePbftExtraHandleMod) HandleforSequentialRequest(som *message.SendOldMessage) bool {
	if int(som.SeqEndHeight-som.SeqStartHeight+1) != len(som.OldRequest) {
		rbhm.pbftNode.pl.Plog.Printf("S%dN%d : the SendOldMessage message is not enough\n", rbhm.pbftNode.ShardID, rbhm.pbftNode.NodeID)
		return true
	}
	for height := som.SeqStartHeight; height <= som.SeqEndHeight; height++ {
		r := som.OldRequest[height-som.SeqStartHeight]
		if r.RequestType == message.BlockRequest {
			b := core.DecodeB(r.Msg.Content)
			rbhm.pbftNode.CurChain.AddBlock(b)
		}
	}
	rbhm.pbftNode.sequenceID = som.SeqEndHeight + 1
	rbhm.pbftNode.CurChain.PrintBlockChain()
	return true
}
