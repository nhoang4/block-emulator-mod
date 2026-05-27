package networks

import (
	"blockEmulator/params"
	"bytes"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"

	"math/rand"

	"golang.org/x/time/rate"
)

var connMaplock sync.Mutex
var connectionPool = make(map[string]net.Conn, 0)

// network params.
var randomDelayGenerator *rand.Rand
var rateLimiterDownload *rate.Limiter
var rateLimiterUpload *rate.Limiter

const (
	tcpDialAttempts = 6
	tcpDialBackoff  = 250 * time.Millisecond
)

// Define the latency, jitter and bandwidth here.
// Init tools.
func InitNetworkTools() {
	// avoid wrong params.
	if params.Delay < 0 {
		params.Delay = 0
	}
	if params.JitterRange < 0 {
		params.JitterRange = 0
	}
	if params.Bandwidth < 0 {
		params.Bandwidth = 0x7fffffff
	}

	// generate the random seed.
	randomDelayGenerator = rand.New(rand.NewSource(time.Now().UnixMicro()))
	// Limit the download rate
	rateLimiterDownload = rate.NewLimiter(rate.Limit(params.Bandwidth), params.Bandwidth)
	// Limit the upload rate
	rateLimiterUpload = rate.NewLimiter(rate.Limit(params.Bandwidth), params.Bandwidth)
}

func TcpDial(context []byte, addr string) {
	go func() {
		if err := TcpDialSync(context, addr, tcpDialAttempts); err != nil {
			log.Printf("TcpDial failed to %s after %d attempts: %v\n", addr, tcpDialAttempts, err)
		}
	}()
}

func TcpDialSync(context []byte, addr string, attempts int) error {
	if attempts < 1 {
		attempts = 1
	}

	connMsg := make([]byte, 0, len(context)+1)
	connMsg = append(connMsg, context...)
	connMsg = append(connMsg, '\n')

	// simulate the delay
	thisDelay := params.Delay
	if params.JitterRange != 0 {
		thisDelay = randomDelayGenerator.Intn(params.JitterRange) - params.JitterRange/2 + params.Delay
	}
	time.Sleep(time.Millisecond * time.Duration(thisDelay))

	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		if err := tcpDialOnce(connMsg, addr); err != nil {
			lastErr = err
			time.Sleep(time.Duration(attempt) * tcpDialBackoff)
			continue
		}
		return nil
	}
	return lastErr
}

func tcpDialOnce(connMsg []byte, addr string) error {
	connMaplock.Lock()
	defer connMaplock.Unlock()

	var err error
	var conn net.Conn

	if c, ok := connectionPool[addr]; ok {
		if tcpConn, tcpOk := c.(*net.TCPConn); tcpOk {
			if err := tcpConn.SetKeepAlive(true); err != nil {
				_ = c.Close()
				delete(connectionPool, addr)
			} else {
				conn = c
			}
		}
	}

	if conn == nil {
		conn, err = net.DialTimeout("tcp", addr, 2*time.Second)
		if err != nil {
			return fmt.Errorf("connect: %w", err)
		}
		connectionPool[addr] = conn
	}

	if err := writeToConn(connMsg, conn, rateLimiterUpload); err != nil {
		_ = conn.Close()
		delete(connectionPool, addr)
		return fmt.Errorf("write: %w", err)
	}
	return nil
}

// Broadcast sends a message to multiple receivers, excluding the sender.
func Broadcast(sender string, receivers []string, msg []byte) {
	for _, ip := range receivers {
		if ip == sender {
			continue
		}
		go TcpDial(msg, ip)
	}
}

// CloseAllConnInPool closes all connections in the connection pool.
func CloseAllConnInPool() {
	connMaplock.Lock()
	defer connMaplock.Unlock()

	for _, conn := range connectionPool {
		conn.Close()
	}
	connectionPool = make(map[string]net.Conn) // Reset the pool
}

// ReadFromConn reads data from a connection.
func ReadFromConn(addr string) {
	conn := connectionPool[addr]

	// new a conn reader
	connReader := NewConnReader(conn, rateLimiterDownload)

	buffer := make([]byte, 1024)
	var messageBuffer bytes.Buffer

	for {
		n, err := connReader.Read(buffer)
		if err != nil {
			if err != io.EOF {
				log.Println("Read error for address", addr, ":", err)
			}
			break
		}

		// add message to buffer
		messageBuffer.Write(buffer[:n])

		// handle the full message
		for {
			message, err := readMessage(&messageBuffer)
			if err == io.ErrShortBuffer {
				// continue to load if buffer is short
				break
			} else if err == nil {
				// log the full message
				log.Println("Received from", addr, ":", message)
			} else {
				// handle other errs
				log.Println("Error processing message for address", addr, ":", err)
				break
			}
		}
	}
}

func readMessage(buffer *bytes.Buffer) (string, error) {
	message, err := buffer.ReadBytes('\n')
	if err != nil && err != io.EOF {
		return "", err
	}
	return string(message), nil
}
