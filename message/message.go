package message

import (
	"blockEmulator/core"
	"blockEmulator/shard"
	"math/big"
	"time"

	"github.com/niclabs/tcrsa"
)

var prefixMSGtypeLen = 30

type MessageType string
type RequestType string

const (
	CPrePrepare        MessageType = "preprepare"
	CPrepare           MessageType = "prepare"
	CCommit            MessageType = "commit"
	CRequestOldrequest MessageType = "requestOldrequest"
	CSendOldrequest    MessageType = "sendOldrequest"
	CStop              MessageType = "stop"

	CRelay          MessageType = "relay"
	CRelayWithProof MessageType = "CRelay&Proof"
	CInject         MessageType = "inject"

	CBlockInfo MessageType = "BlockInfo"
	CSeqIDinfo MessageType = "SequenceID"

	CBridgeOverlay MessageType = "BridgeOverlay"
)

var (
	BlockRequest RequestType = "Block"
	// add more types
	// ...
)

type RawMessage struct {
	Content []byte // the content of raw message, txs and blocks (most cases) included
}

type Request struct {
	RequestType RequestType
	Msg         RawMessage // request message
	ReqTime     time.Time  // request time
}

type PrePrepare struct {
	RequestMsg *Request // the request message should be pre-prepared
	Digest     []byte   // the digest of this request, which is the only identifier
	SeqID      uint64

	// Optional ShardBridge threshold-signature payload. Empty for other protocols.
	B           []byte
	BlockBPKCS1 []byte
}

type Prepare struct {
	Digest     []byte // To identify which request is prepared by this node
	SeqID      uint64
	SenderNode *shard.Node // To identify who send this message
}

type Commit struct {
	Digest     []byte          // To identify which request is prepared by this node
	SeqID      uint64          // PBFT sequence id
	SenderNode *shard.Node     // To identify who send this message
	PartialSig *tcrsa.SigShare // Optional ShardBridge threshold-signature share.
}

type Reply struct {
	MessageID  uint64
	SenderNode *shard.Node
	Result     bool
}

type RequestOldMessage struct {
	SeqStartHeight uint64
	SeqEndHeight   uint64
	ServerNode     *shard.Node // send this request to the server node
	SenderNode     *shard.Node
}

type SendOldMessage struct {
	SeqStartHeight uint64
	SeqEndHeight   uint64
	OldRequest     []*Request
	SenderNode     *shard.Node
}

type InjectTxs struct {
	Txs       []*core.Transaction
	ToShardID uint64
}

// data sent to the supervisor
type BlockInfoMsg struct {
	BlockBodyLength int
	InnerShardTxs   []*core.Transaction // txs which are innerShard
	Epoch           int

	ProposeTime   time.Time // record the propose time of this block (txs)
	CommitTime    time.Time // record the commit time of this block (txs)
	SenderShardID uint64

	// for transaction relay
	Relay1Txs []*core.Transaction // relay1 transactions in chain first time
	Relay2Txs []*core.Transaction // relay2 transactions in chain second time

	// for broker
	Broker1Txs []*core.Transaction // cross transactions at first time by broker
	Broker2Txs []*core.Transaction // cross transactions at second time by broker

	// for bridge
	Bridge1Txs       []*core.Transaction // cross transactions at first time by bridge
	Bridge2Txs       []*core.Transaction // cross transactions at second time by bridge
	BridgeForwardTxs []*core.Transaction // overlay forwarding hops, excluded from logical tx metrics
	JointSig         tcrsa.Signature     // optional ShardBridge joint signature
}

type BridgeOverlayMsg struct {
	Epoch        int
	DegreeLimits []int
	Edges        [][2]uint64
	Routes       [][][]uint64
}

type SeqIDinfo struct {
	SenderShardID uint64
	SenderSeq     uint64

	// Optional ShardBridge fields. Extra JSON fields are ignored by other protocols.
	Tx2s       []*core.Transaction
	SenderNode *shard.Node
	Values     map[uint64]*big.Int
	JointSig   tcrsa.Signature
}

func MergeMessage(msgType MessageType, content []byte) []byte {
	b := make([]byte, prefixMSGtypeLen)
	for i, v := range []byte(msgType) {
		b[i] = v
	}
	merge := append(b, content...)
	return merge
}

func SplitMessage(message []byte) (MessageType, []byte) {
	msgTypeBytes := message[:prefixMSGtypeLen]
	msgType_pruned := make([]byte, 0)
	for _, v := range msgTypeBytes {
		if v != byte(0) {
			msgType_pruned = append(msgType_pruned, v)
		}
	}
	msgType := string(msgType_pruned)
	content := message[prefixMSGtypeLen:]
	return MessageType(msgType), content
}
