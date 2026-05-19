package committee

import (
	"blockEmulator/core"
	"blockEmulator/message"
	"blockEmulator/networks"
	"blockEmulator/params"
	"blockEmulator/pcn"
	"blockEmulator/supervisor/signal"
	"blockEmulator/supervisor/supervisor_log"
	"blockEmulator/utils"
	"crypto/sha256"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"os"
	"sync"
	"time"
)

type BridgeCommitteeMod struct {
	csvPath      string
	dataTotalNum int
	nowDataNum   int
	batchDataNum int

	bridges          *pcn.Bridges
	bridgeModuleLock sync.Mutex
	rawCrossTxNum    int
	normalCommitNum  int
	bridge1CommitNum int
	bridge2CommitNum int
	overlayEnabled   bool
	overlayEpoch     int
	overlay          *pcn.Overlay
	degreeLimits     []int
	nextTraffic      [][]int64

	sl *supervisor_log.SupervisorLog

	Ss          *signal.StopSignal
	IpNodeTable map[uint64]map[uint64]string
}

func NewBridgeCommitteeMod(IpNodeTable map[uint64]map[uint64]string, Ss *signal.StopSignal, sl *supervisor_log.SupervisorLog, csvFilePath string, dataNum, batchNum int) *BridgeCommitteeMod {
	bridges := new(pcn.Bridges)
	bridges.NewBridges(nil, pcn.NewBridgeAddresses(params.ShardNum))

	bcm := &BridgeCommitteeMod{
		csvPath:      csvFilePath,
		dataTotalNum: dataNum,
		batchDataNum: batchNum,
		nowDataNum:   0,
		bridges:      bridges,
		IpNodeTable:  IpNodeTable,
		Ss:           Ss,
		sl:           sl,
	}
	bcm.initBridgeOverlay()
	return bcm
}

func (bcm *BridgeCommitteeMod) HandleOtherMessage([]byte) {}

func (bcm *BridgeCommitteeMod) fetchModifiedMap(key string) uint64 {
	return uint64(utils.Addr2Shard(key))
}

func (bcm *BridgeCommitteeMod) MsgSendingControl() {
	txfile, err := os.Open(bcm.csvPath)
	if err != nil {
		log.Panic(err)
	}
	defer txfile.Close()

	if bcm.overlayEnabled {
		bcm.broadcastBridgeOverlay()
	}

	reader := csv.NewReader(txfile)
	txlist := make([]*core.Transaction, 0)
	for {
		data, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			log.Panic(err)
		}
		if tx, ok := data2tx(data, uint64(bcm.nowDataNum)); ok {
			txlist = append(txlist, tx)
			bcm.nowDataNum++
		} else {
			continue
		}

		if len(txlist) == bcm.batchDataNum || bcm.nowDataNum == bcm.dataTotalNum {
			itx := bcm.dealTxByBridge(txlist)
			bcm.txSending(itx)
			txlist = make([]*core.Transaction, 0)
			bcm.Ss.StopGap_Reset()
			if bcm.overlayEnabled && bcm.nowDataNum < bcm.dataTotalNum {
				bcm.rotateBridgeOverlay()
			}
		}
		if bcm.nowDataNum == bcm.dataTotalNum {
			break
		}
	}
}

func (bcm *BridgeCommitteeMod) txSending(txlist []*core.Transaction) {
	sendToShard := make(map[uint64][]*core.Transaction)

	for idx := 0; idx <= len(txlist); idx++ {
		if idx > 0 && (idx%params.InjectSpeed == 0 || idx == len(txlist)) {
			for sid := uint64(0); sid < uint64(params.ShardNum); sid++ {
				if len(sendToShard[sid]) == 0 {
					continue
				}
				it := message.InjectTxs{
					Txs:       sendToShard[sid],
					ToShardID: sid,
				}
				itByte, err := json.Marshal(it)
				if err != nil {
					log.Panic(err)
				}
				sendMsg := message.MergeMessage(message.CInject, itByte)
				go networks.TcpDial(sendMsg, bcm.IpNodeTable[sid][0])
			}
			sendToShard = make(map[uint64][]*core.Transaction)
			time.Sleep(time.Second)
		}
		if idx == len(txlist) {
			break
		}

		tx := txlist[idx]
		senderSID := bcm.fetchModifiedMap(tx.Sender)
		if bcm.bridges.IsBridgeAccount(tx.Sender) {
			senderSID = bcm.fetchModifiedMap(tx.Recipient)
		}
		sendToShard[senderSID] = append(sendToShard[senderSID], tx)
	}
}

func (bcm *BridgeCommitteeMod) dealTxByBridge(txs []*core.Transaction) []*core.Transaction {
	itxs := make([]*core.Transaction, 0)
	bridgeRawMegs := make([]*message.BridgeRawMeg, 0)
	for _, tx := range txs {
		rSID := bcm.fetchModifiedMap(tx.Recipient)
		sSID := bcm.fetchModifiedMap(tx.Sender)
		if rSID != sSID && !bcm.bridges.IsBridgeAccount(tx.Recipient) && !bcm.bridges.IsBridgeAccount(tx.Sender) {
			route := []uint64{sSID, rSID}
			overlayEpoch := 0
			if bcm.overlayEnabled {
				route = bcm.bridgeRoute(sSID, rSID)
				overlayEpoch = bcm.overlayEpoch
				bcm.recordBridgeTraffic(sSID, rSID)
			}
			bridgeRawMegs = append(bridgeRawMegs, &message.BridgeRawMeg{
				Tx:                 tx,
				ShardID:            int(sSID),
				Route:              route,
				BridgeOverlayEpoch: overlayEpoch,
			})
			continue
		}

		if bcm.bridges.IsBridgeAccount(tx.Recipient) || bcm.bridges.IsBridgeAccount(tx.Sender) {
			tx.HasBridge = true
			tx.SenderIsBridge = bcm.bridges.IsBridgeAccount(tx.Sender)
		}
		itxs = append(itxs, tx)
	}

	if len(bridgeRawMegs) != 0 {
		bcm.handleBridgeRawMag(bridgeRawMegs)
	}
	return itxs
}

func (bcm *BridgeCommitteeMod) handleBridgeRawMag(bridgeRawMegs []*message.BridgeRawMeg) {
	bridgeType1Megs := make([]*message.BridgeType1Meg, 0)
	bcm.bridgeModuleLock.Lock()
	bcm.rawCrossTxNum += len(bridgeRawMegs)
	for _, meg := range bridgeRawMegs {
		bcm.bridges.BridgeRawMegs[string(bcm.getBridgeRawMagDigest(meg))] = meg
		bridgeType1Megs = append(bridgeType1Megs, &message.BridgeType1Meg{
			RawMeg:   meg,
			Hcurrent: 0,
			ShardID:  meg.ShardID,
		})
	}
	bcm.bridgeModuleLock.Unlock()
	bcm.handleBridgeType1Mes(bridgeType1Megs)
}

func (bcm *BridgeCommitteeMod) handleBridgeType1Mes(bridgeType1Megs []*message.BridgeType1Meg) {
	tx1s := make([]*core.Transaction, 0)
	for _, bridgeType1Meg := range bridgeType1Megs {
		if bridgeType1Meg.ShardID < 0 || bridgeType1Meg.ShardID >= len(bcm.bridges.Addrs) {
			continue
		}
		ctx := bridgeType1Meg.RawMeg.Tx
		tx1 := core.NewTransaction(ctx.Sender, bcm.bridges.Addrs[bridgeType1Meg.ShardID], ctx.Value, ctx.Nonce, time.Now())
		tx1.HasBridge = true
		tx1.OriginalSender = ctx.Sender
		tx1.FinalRecipient = ctx.Recipient
		tx1.RawTxHash = make([]byte, len(ctx.TxHash))
		copy(tx1.RawTxHash, ctx.TxHash)
		tx1.BridgeRoute = append([]uint64(nil), bridgeType1Meg.RawMeg.Route...)
		tx1.BridgeRouteIndex = 0
		tx1.BridgeOverlayEpoch = bridgeType1Meg.RawMeg.BridgeOverlayEpoch
		tx1s = append(tx1s, tx1)
	}
	bcm.txSending(tx1s)
}

func (bcm *BridgeCommitteeMod) getBridgeRawMagDigest(r *message.BridgeRawMeg) []byte {
	b, err := json.Marshal(r)
	if err != nil {
		log.Panic(err)
	}
	hash := sha256.Sum256(b)
	return hash[:]
}

func (bcm *BridgeCommitteeMod) HandleBlockInfo(b *message.BlockInfoMsg) {
	bcm.sl.Slog.Printf("received bridge block from shard %d in epoch %d.\n", b.SenderShardID, b.Epoch)
	if b.BlockBodyLength == 0 {
		return
	}

	bcm.bridgeModuleLock.Lock()
	bcm.normalCommitNum += len(b.InnerShardTxs)
	bcm.bridge1CommitNum += len(b.Bridge1Txs)
	bcm.bridge2CommitNum += len(b.Bridge2Txs)
	bcm.bridgeModuleLock.Unlock()
}

func (bcm *BridgeCommitteeMod) ExecutionDrained() bool {
	bcm.bridgeModuleLock.Lock()
	defer bcm.bridgeModuleLock.Unlock()

	expectedNormal := bcm.dataTotalNum - bcm.rawCrossTxNum
	if expectedNormal < 0 {
		expectedNormal = 0
	}
	return bcm.normalCommitNum >= expectedNormal &&
		bcm.bridge1CommitNum >= bcm.rawCrossTxNum &&
		bcm.bridge2CommitNum >= bcm.rawCrossTxNum
}

func (bcm *BridgeCommitteeMod) DrainStatus() string {
	bcm.bridgeModuleLock.Lock()
	defer bcm.bridgeModuleLock.Unlock()

	expectedNormal := bcm.dataTotalNum - bcm.rawCrossTxNum
	if expectedNormal < 0 {
		expectedNormal = 0
	}
	return fmt.Sprintf(
		"normal %d/%d, bridge1 %d/%d, bridge2 %d/%d",
		bcm.normalCommitNum,
		expectedNormal,
		bcm.bridge1CommitNum,
		bcm.rawCrossTxNum,
		bcm.bridge2CommitNum,
		bcm.rawCrossTxNum,
	)
}

func (bcm *BridgeCommitteeMod) initBridgeOverlay() {
	bcm.overlayEnabled = params.BridgeOverlayEnabled != 0
	if !bcm.overlayEnabled {
		return
	}

	shardNum := params.ShardNum
	minDegree := params.BridgeOverlayMinDegree
	maxDegree := params.BridgeOverlayMaxDegree
	if shardNum > 1 && maxDegree > shardNum-1 {
		maxDegree = shardNum - 1
	}
	if minDegree > maxDegree {
		minDegree = maxDegree
	}
	if minDegree < 1 {
		minDegree = 1
	}

	rng := rand.New(rand.NewSource(params.BridgeOverlaySeed))
	bcm.degreeLimits = make([]int, shardNum)
	for sid := 0; sid < shardNum; sid++ {
		if maxDegree == minDegree {
			bcm.degreeLimits[sid] = minDegree
			continue
		}
		bcm.degreeLimits[sid] = minDegree + rng.Intn(maxDegree-minDegree+1)
	}
	bcm.overlayEpoch = 0
	bcm.overlay = pcn.NewCompleteOverlay(shardNum)
	bcm.nextTraffic = makeBridgeTrafficMatrix(shardNum)
	bcm.sl.Slog.Printf("bridge overlay enabled: epoch %d starts with complete graph, build mode %s, degree limits %v\n", bcm.overlayEpoch, bridgeOverlayBuildModeName(), bcm.degreeLimits)
}

func (bcm *BridgeCommitteeMod) bridgeRoute(sourceSID, destSID uint64) []uint64 {
	if bcm.overlay == nil {
		return []uint64{sourceSID, destSID}
	}
	route := bcm.overlay.Route(sourceSID, destSID)
	if len(route) == 0 {
		return []uint64{sourceSID, destSID}
	}
	return route
}

func (bcm *BridgeCommitteeMod) recordBridgeTraffic(sourceSID, destSID uint64) {
	if int(sourceSID) >= len(bcm.nextTraffic) || int(destSID) >= len(bcm.nextTraffic) {
		return
	}
	bcm.nextTraffic[sourceSID][destSID]++
	bcm.nextTraffic[destSID][sourceSID]++
}

func (bcm *BridgeCommitteeMod) rotateBridgeOverlay() {
	nextOverlay, err := pcn.BuildOverlayWithMode(bcm.nextTraffic, bcm.degreeLimits, bridgeOverlayBuildMode())
	if err != nil {
		bcm.sl.Slog.Printf("bridge overlay build failed for epoch %d: %v; falling back to complete graph\n", bcm.overlayEpoch+1, err)
		nextOverlay = pcn.NewCompleteOverlay(params.ShardNum)
	}
	bcm.overlayEpoch++
	bcm.overlay = nextOverlay
	bcm.nextTraffic = makeBridgeTrafficMatrix(params.ShardNum)
	bcm.sl.Slog.Printf("bridge overlay epoch %d selected %d edges using %s mode\n", bcm.overlayEpoch, len(bcm.overlay.Edges), bridgeOverlayBuildModeName())
	bcm.broadcastBridgeOverlay()
}

func bridgeOverlayBuildMode() pcn.OverlayBuildMode {
	switch params.BridgeOverlayBuildMode {
	case int(pcn.OverlayBuildTreeOnly):
		return pcn.OverlayBuildTreeOnly
	case int(pcn.OverlayBuildBinaryTree):
		return pcn.OverlayBuildBinaryTree
	default:
		return pcn.OverlayBuildFull
	}
}

func bridgeOverlayBuildModeName() string {
	switch bridgeOverlayBuildMode() {
	case pcn.OverlayBuildTreeOnly:
		return "tree-only"
	case pcn.OverlayBuildBinaryTree:
		return "binary-tree"
	default:
		return "full"
	}
}

func (bcm *BridgeCommitteeMod) broadcastBridgeOverlay() {
	if bcm.overlay == nil {
		return
	}
	msg := message.BridgeOverlayMsg{
		Epoch:        bcm.overlayEpoch,
		DegreeLimits: append([]int(nil), bcm.degreeLimits...),
		Edges:        overlayEdgesForMessage(bcm.overlay.Edges),
		Routes:       bcm.overlay.Routes,
	}
	msgByte, err := json.Marshal(msg)
	if err != nil {
		log.Panic(err)
	}
	sendMsg := message.MergeMessage(message.CBridgeOverlay, msgByte)
	for sid := uint64(0); sid < uint64(params.ShardNum); sid++ {
		for nid := uint64(0); nid < uint64(params.NodesInShard); nid++ {
			go networks.TcpDial(sendMsg, bcm.IpNodeTable[sid][nid])
		}
	}
	bcm.sl.Slog.Printf("broadcast bridge overlay epoch %d to all shards, edges %d\n", bcm.overlayEpoch, len(bcm.overlay.Edges))
}

func makeBridgeTrafficMatrix(shardNum int) [][]int64 {
	matrix := make([][]int64, shardNum)
	for i := 0; i < shardNum; i++ {
		matrix[i] = make([]int64, shardNum)
	}
	return matrix
}

func overlayEdgesForMessage(edges []pcn.OverlayEdge) [][2]uint64 {
	msgEdges := make([][2]uint64, len(edges))
	for i, edge := range edges {
		msgEdges[i] = [2]uint64{edge.U, edge.V}
	}
	return msgEdges
}
