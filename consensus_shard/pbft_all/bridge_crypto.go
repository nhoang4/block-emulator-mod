package pbft_all

import (
	"blockEmulator/message"
	"blockEmulator/params"
	"blockEmulator/pcn"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/json"
	"log"
	"math/big"
	"os"
	"path/filepath"
	"strconv"

	"github.com/niclabs/tcrsa"
)

func (p *PbftConsensusNode) initBridgeState() {
	bridges := new(pcn.Bridges)
	bridges.NewBridges(p.pbftChainConfig, pcn.NewBridgeAddresses(params.ShardNum))
	p.bridges = bridges

	p.bridgeBalances = make(map[uint64]*big.Int, params.ShardNum)
	for sid := uint64(0); sid < uint64(params.ShardNum); sid++ {
		p.bridgeBalances[sid] = new(big.Int).Set(params.Init_Balance)
	}

	p.bridgeSigShares = make(tcrsa.SigShareList, 0)
	p.bridgeSigSeen = make(map[uint64]bool)
	p.bridgeOverlayEpoch = 0
	p.bridgeDegreeLimits = make([]int, 0)
	p.bridgeOverlayEdges = make([][2]uint64, 0)
	p.bridgeOverlayRoutes = make([][][]uint64, 0)
	p.loadBridgeSignatureMaterial()
}

func (p *PbftConsensusNode) isBridgeMode() bool {
	return p.bridges != nil
}

func (p *PbftConsensusNode) resetBridgeSignatureRound() {
	p.bridgePreparedHash = nil
	p.bridgePreparedPKCS1 = nil
	p.bridgePartialSig = nil
	p.bridgeJointSig = nil
	p.bridgeSigShares = make(tcrsa.SigShareList, 0)
	p.bridgeSigSeen = make(map[uint64]bool)
}

func (p *PbftConsensusNode) loadBridgeSignatureMaterial() {
	metaPath, sharesPath := p.bridgeSignatureMaterialPaths()

	metaJSON, err := os.ReadFile(metaPath)
	if err != nil {
		log.Panicf("ShardBridge requires threshold signatures, but cannot read %s: %v", metaPath, err)
	}
	var meta tcrsa.KeyMeta
	if err := json.Unmarshal(metaJSON, &meta); err != nil {
		log.Panicf("ShardBridge requires threshold signatures, but cannot unmarshal %s: %v", metaPath, err)
	}
	if meta.PublicKey == nil {
		log.Panicf("ShardBridge requires threshold signatures, but %s has no public key", metaPath)
	}

	sharesJSON, err := os.ReadFile(sharesPath)
	if err != nil {
		log.Panicf("ShardBridge requires threshold signatures, but cannot read %s: %v", sharesPath, err)
	}
	var shares tcrsa.KeyShareList
	if err := json.Unmarshal(sharesJSON, &shares); err != nil {
		log.Panicf("ShardBridge requires threshold signatures, but cannot unmarshal %s: %v", sharesPath, err)
	}
	if int(p.NodeID) >= len(shares) || shares[p.NodeID] == nil {
		log.Panicf("ShardBridge requires threshold signatures, but %s has no share for node %d", sharesPath, p.NodeID)
	}
	if int(meta.L) < params.NodesInShard {
		log.Panicf("ShardBridge signature material %s only has %d shares, but this run needs %d nodes per shard", metaPath, meta.L, params.NodesInShard)
	}

	p.bridgeMeta = meta
	p.bridgeShare = *shares[p.NodeID]
}

func (p *PbftConsensusNode) bridgeSignatureMaterialPaths() (string, string) {
	if params.BridgeKeyRootDir != "" {
		keyDir := filepath.Join(params.BridgeKeyRootDir, "n"+strconv.Itoa(params.NodesInShard))
		metaPath := filepath.Join(keyDir, "metadata.json")
		sharesPath := filepath.Join(keyDir, "shares.json")
		if _, err := os.Stat(metaPath); err == nil {
			if _, err := os.Stat(sharesPath); err == nil {
				return metaPath, sharesPath
			}
		}
	}
	return "metadata.json", "shares.json"
}

func (p *PbftConsensusNode) prepareBridgeHash(msg []byte) {
	h := sha256.New()
	h.Write(msg)
	p.bridgePreparedHash = h.Sum(nil)
	blockBPKCS1, err := tcrsa.PrepareDocumentHash(p.bridgeMeta.PublicKey.Size(), crypto.SHA256, p.bridgePreparedHash)
	if err != nil {
		log.Panicf("ShardBridge threshold hash preparation failed: %v", err)
	}
	p.bridgePreparedPKCS1 = blockBPKCS1
}

func (p *PbftConsensusNode) prepareBridgeHashForDigest(digest []byte) bool {
	r, ok := p.requestPool[string(digest)]
	if !ok || r == nil {
		p.pl.Plog.Printf("S%dN%d : cannot prepare bridge signature, missing request for digest %x\n", p.ShardID, p.NodeID, digest)
		return false
	}
	if r.RequestType != message.BlockRequest {
		p.pl.Plog.Printf("S%dN%d : cannot prepare bridge signature for non-block request\n", p.ShardID, p.NodeID)
		return false
	}
	p.prepareBridgeHash(r.Msg.Content)
	return true
}

func (p *PbftConsensusNode) partialSignBridge() bool {
	if len(p.bridgePreparedPKCS1) == 0 {
		p.pl.Plog.Printf("S%dN%d : cannot partially sign before preparing the bridge block hash\n", p.ShardID, p.NodeID)
		return false
	}
	partialSig, err := (&p.bridgeShare).Sign(p.bridgePreparedPKCS1, crypto.SHA256, &p.bridgeMeta)
	if err != nil {
		p.pl.Plog.Printf("S%dN%d : bridge partial signature failed: %v\n", p.ShardID, p.NodeID, err)
		return false
	}
	p.bridgePartialSig = partialSig
	return true
}

func (p *PbftConsensusNode) collectBridgePartialSig(senderID uint64, partialSig *tcrsa.SigShare) {
	if p.NodeID != uint64(p.view.Load()) {
		return
	}
	if partialSig == nil {
		p.pl.Plog.Printf("S%dN%d : ignoring nil bridge partial signature from node %d\n", p.ShardID, p.NodeID, senderID)
		return
	}
	if p.bridgeSigSeen[senderID] {
		return
	}
	p.bridgeSigSeen[senderID] = true
	p.bridgeSigShares = append(p.bridgeSigShares, partialSig)
}

func (p *PbftConsensusNode) collectBridgeCommitSig(cmsg *message.Commit) {
	if cmsg == nil || cmsg.SenderNode == nil {
		return
	}
	p.collectBridgePartialSig(cmsg.SenderNode.NodeID, cmsg.PartialSig)
}

func (p *PbftConsensusNode) hasEnoughBridgeSignatureShares() bool {
	return len(p.bridgeSigShares) >= int(p.bridgeMeta.K)
}

func (p *PbftConsensusNode) combineBridgeSignature() bool {
	if len(p.bridgeSigShares) < int(p.bridgeMeta.K) {
		p.pl.Plog.Printf("S%dN%d : bridge has %d signature shares, needs %d\n", p.ShardID, p.NodeID, len(p.bridgeSigShares), p.bridgeMeta.K)
		return false
	}
	sig, err := p.bridgeSigShares.Join(p.bridgePreparedPKCS1, &p.bridgeMeta)
	if err != nil {
		p.pl.Plog.Printf("S%dN%d : bridge joint signature failed: %v\n", p.ShardID, p.NodeID, err)
		return false
	}
	p.bridgeJointSig = sig
	return true
}

func (p *PbftConsensusNode) verifyBridgeSignature() bool {
	if len(p.bridgeJointSig) == 0 {
		p.pl.Plog.Printf("S%dN%d : cannot verify an empty bridge joint signature\n", p.ShardID, p.NodeID)
		return false
	}
	err := rsa.VerifyPKCS1v15(p.bridgeMeta.PublicKey, crypto.SHA256, p.bridgePreparedHash, p.bridgeJointSig)
	if err != nil {
		p.pl.Plog.Printf("S%dN%d : bridge joint signature verification failed: %v\n", p.ShardID, p.NodeID, err)
		return false
	}
	return true
}
