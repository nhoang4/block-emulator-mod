package params

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
)

var (
	// The following parameters can be set in main.go.
	// default values:
	NodesInShard = 4  // \# of Nodes in a shard.
	ShardNum     = 16 // \# of shards.
)

// consensus layer & output file path
var (
	ConsensusMethod = 4 // ConsensusMethod an Integer, which indicates the choice ID of methods / consensuses. Value range: [0, 4], representing [CLPA_Broker, CLPA, Broker, Relay, Bridge].

	PbftViewChangeTimeOut = 300000 // The view change threshold of pbft. If the process of PBFT is too slow, the view change mechanism will be triggered.
	PbftStartDelay        = 5000   // The startup delay before PBFT leaders begin proposing blocks.

	Block_Interval = 4000 // The time interval for generating a new block

	MaxBlockSize_global = 4000  // The maximum number of transactions a block contains
	BlocksizeInBytes    = 20000 // The maximum size (in bytes) of block body
	UseBlocksizeInBytes = 0     // Use blocksizeInBytes as the blocksize measurement if '1'.

	InjectSpeed   = 6000   // The speed of transaction injection
	TotalDataSize = 200000 // The total number of txs to be injected
	TxBatchSize   = 20000  // The supervisor read a batch of txs then send them. The size of a batch is 'TxBatchSize'

	BrokerNum            = 10 // The # of Broker accounts used in Broker / CLPA_Broker.
	RelayWithMerkleProof = 0  // When using a consensus about "Relay", nodes will send Tx Relay with proof if "RelayWithMerkleProof" = 1

	BridgeOverlayEnabled   = 0
	BridgeOverlayBuildMode = 0
	BridgeOverlayMinDegree = 2
	BridgeOverlayMaxDegree = 10
	BridgeOverlaySeed      = int64(1)
	BridgeKeyRootDir       = "./bridge_keys"

	ExpDataRootDir     = "expTest"                     // The root dir where the experimental data should locate.
	DataWrite_path     = ExpDataRootDir + "/result/"   // Measurement data result output path
	LogWrite_path      = ExpDataRootDir + "/log"       // Log output path
	DatabaseWrite_path = ExpDataRootDir + "/database/" // database write path

	SupervisorAddr = "127.0.0.1:18800"                                // Supervisor ip address
	DatasetFile    = `./TxData/1000000to1999999_BlockTransaction.csv` // The raw BlockTransaction data path

	ReconfigTimeGap = 50 // The time gap between epochs. This variable is only used in CLPA / CLPA_Broker now.
)

// network layer
var (
	Delay       int // The delay of network (ms) when sending. 0 if delay < 0
	JitterRange int // The jitter range of delay (ms). Jitter follows a uniform distribution. 0 if JitterRange < 0.
	Bandwidth   int // The bandwidth limit (Bytes). +inf if bandwidth < 0
)

// read from file
type globalConfig struct {
	ConsensusMethod int `json:"ConsensusMethod"`

	ShardNum     int `json:"ShardNum"`
	NodesInShard int `json:"NodesInShard"`

	PbftViewChangeTimeOut int `json:"PbftViewChangeTimeOut"`
	PbftStartDelay        int `json:"PbftStartDelay"`

	ExpDataRootDir string `json:"ExpDataRootDir"`

	BlockInterval int `json:"Block_Interval"`

	BlocksizeInBytes    int `json:"BlocksizeInBytes"`
	MaxBlockSizeGlobal  int `json:"BlockSize"`
	UseBlocksizeInBytes int `json:"UseBlocksizeInBytes"`

	InjectSpeed   int `json:"InjectSpeed"`
	TotalDataSize int `json:"TotalDataSize"`

	TxBatchSize          int    `json:"TxBatchSize"`
	BrokerNum            int    `json:"BrokerNum"`
	RelayWithMerkleProof int    `json:"RelayWithMerkleProof"`
	DatasetFile          string `json:"DatasetFile"`
	ReconfigTimeGap      int    `json:"ReconfigTimeGap"`

	BridgeOverlayEnabled   int    `json:"BridgeOverlayEnabled"`
	BridgeOverlayBuildMode int    `json:"BridgeOverlayBuildMode"`
	BridgeOverlayMinDegree int    `json:"BridgeOverlayMinDegree"`
	BridgeOverlayMaxDegree int    `json:"BridgeOverlayMaxDegree"`
	BridgeOverlaySeed      int64  `json:"BridgeOverlaySeed"`
	BridgeKeyRootDir       string `json:"BridgeKeyRootDir"`

	Delay       int `json:"Delay"`
	JitterRange int `json:"JitterRange"`
	Bandwidth   int `json:"Bandwidth"`
}

func ReadConfigFile() {
	// read configurations from paramsConfig.json, unless a launch script provides
	// an isolated config file for this process.
	configPath := os.Getenv("PARAMS_CONFIG")
	if configPath == "" {
		configPath = "paramsConfig.json"
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		log.Fatalf("Error reading config file %s: %v", configPath, err)
	}
	var config globalConfig
	err = json.Unmarshal(data, &config)
	if err != nil {
		log.Fatalf("Error unmarshalling JSON: %v", err)
	}

	// output configurations
	fmt.Printf("Config: %+v\n", config)

	// set configurations to params
	// consensus params
	ConsensusMethod = config.ConsensusMethod
	if config.ShardNum > 0 {
		ShardNum = config.ShardNum
	}
	if config.NodesInShard > 0 {
		NodesInShard = config.NodesInShard
	}

	PbftViewChangeTimeOut = config.PbftViewChangeTimeOut
	if config.PbftStartDelay > 0 {
		PbftStartDelay = config.PbftStartDelay
	}

	// data file params
	ExpDataRootDir = config.ExpDataRootDir
	DataWrite_path = ExpDataRootDir + "/result/"
	LogWrite_path = ExpDataRootDir + "/log"
	DatabaseWrite_path = ExpDataRootDir + "/database/"

	Block_Interval = config.BlockInterval

	MaxBlockSize_global = config.MaxBlockSizeGlobal
	BlocksizeInBytes = config.BlocksizeInBytes
	UseBlocksizeInBytes = config.UseBlocksizeInBytes

	InjectSpeed = config.InjectSpeed
	TotalDataSize = config.TotalDataSize
	TxBatchSize = config.TxBatchSize

	BrokerNum = config.BrokerNum
	RelayWithMerkleProof = config.RelayWithMerkleProof
	DatasetFile = config.DatasetFile

	ReconfigTimeGap = config.ReconfigTimeGap

	BridgeOverlayEnabled = config.BridgeOverlayEnabled
	BridgeOverlayBuildMode = config.BridgeOverlayBuildMode
	if config.BridgeOverlayMinDegree > 0 {
		BridgeOverlayMinDegree = config.BridgeOverlayMinDegree
	}
	if config.BridgeOverlayMaxDegree > 0 {
		BridgeOverlayMaxDegree = config.BridgeOverlayMaxDegree
	}
	if BridgeOverlayMaxDegree < BridgeOverlayMinDegree {
		BridgeOverlayMaxDegree = BridgeOverlayMinDegree
	}
	BridgeOverlaySeed = config.BridgeOverlaySeed
	if config.BridgeKeyRootDir != "" {
		BridgeKeyRootDir = config.BridgeKeyRootDir
	}

	// network params
	Delay = config.Delay
	JitterRange = config.JitterRange
	Bandwidth = config.Bandwidth
}
