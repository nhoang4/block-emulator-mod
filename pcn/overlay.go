package pcn

import (
	"errors"
	"sort"
)

type OverlayEdge struct {
	U uint64
	V uint64
}

type Overlay struct {
	ShardNum uint64
	Edges    []OverlayEdge
	Routes   [][][]uint64
	Dist     [][]int
}

type OverlayBuildMode int

const (
	OverlayBuildFull OverlayBuildMode = iota
	OverlayBuildTreeOnly
	OverlayBuildBinaryTree
)

type weightedPair struct {
	u uint64
	v uint64
	w int64
}

type dsu struct {
	parent []uint64
	rank   []int
}

func newDSU(n uint64) *dsu {
	d := &dsu{
		parent: make([]uint64, n),
		rank:   make([]int, n),
	}
	for i := uint64(0); i < n; i++ {
		d.parent[i] = i
	}
	return d
}

func (d *dsu) find(x uint64) uint64 {
	if d.parent[x] != x {
		d.parent[x] = d.find(d.parent[x])
	}
	return d.parent[x]
}

func (d *dsu) union(a, b uint64) bool {
	ra := d.find(a)
	rb := d.find(b)
	if ra == rb {
		return false
	}
	if d.rank[ra] < d.rank[rb] {
		d.parent[ra] = rb
		return true
	}
	if d.rank[ra] > d.rank[rb] {
		d.parent[rb] = ra
		return true
	}
	d.parent[rb] = ra
	d.rank[ra]++
	return true
}

func NewCompleteOverlay(shardNum int) *Overlay {
	edges := make([]OverlayEdge, 0)
	for i := uint64(0); i < uint64(shardNum); i++ {
		for j := i + 1; j < uint64(shardNum); j++ {
			edges = append(edges, OverlayEdge{U: i, V: j})
		}
	}
	overlay, _ := newOverlay(uint64(shardNum), edges)
	return overlay
}

func BuildOverlay(weights [][]int64, degreeLimits []int) (*Overlay, error) {
	return BuildOverlayWithMode(weights, degreeLimits, OverlayBuildFull)
}

func BuildTreeOverlay(weights [][]int64, degreeLimits []int) (*Overlay, error) {
	return BuildOverlayWithMode(weights, degreeLimits, OverlayBuildTreeOnly)
}

func BuildBinaryTreeOverlay(shardNum int) (*Overlay, error) {
	if shardNum <= 0 {
		return nil, errors.New("overlay requires at least one shard")
	}
	edges := make([]OverlayEdge, 0, shardNum-1)
	for sid := uint64(1); sid < uint64(shardNum); sid++ {
		edges = append(edges, OverlayEdge{
			U: (sid - 1) / 2,
			V: sid,
		})
	}
	return newOverlay(uint64(shardNum), edges)
}

func BuildOverlayWithMode(weights [][]int64, degreeLimits []int, mode OverlayBuildMode) (*Overlay, error) {
	n := uint64(len(degreeLimits))
	if n == 0 {
		return nil, errors.New("overlay requires at least one shard")
	}
	if mode == OverlayBuildBinaryTree {
		return BuildBinaryTreeOverlay(int(n))
	}
	if len(weights) < int(n) {
		return nil, errors.New("overlay weight matrix is smaller than shard count")
	}
	for i := uint64(0); i < n; i++ {
		if len(weights[i]) < int(n) {
			return nil, errors.New("overlay weight matrix row is smaller than shard count")
		}
		if degreeLimits[i] < 2 && n > 2 {
			return nil, errors.New("overlay degree limits must be at least 2")
		}
	}

	pairs := sortedWeightedPairs(weights)
	degrees := make([]int, n)
	edges := make([]OverlayEdge, 0, n-1)
	treeDSU := newDSU(n)

	for _, pair := range pairs {
		if len(edges) == int(n)-1 {
			break
		}
		if treeDSU.find(pair.u) == treeDSU.find(pair.v) {
			continue
		}
		if degrees[pair.u] >= degreeLimits[pair.u] || degrees[pair.v] >= degreeLimits[pair.v] {
			continue
		}
		edges = append(edges, OverlayEdge{U: pair.u, V: pair.v})
		degrees[pair.u]++
		degrees[pair.v]++
		treeDSU.union(pair.u, pair.v)
	}

	if len(edges) != int(n)-1 {
		return nil, errors.New("degree-constrained spanning tree could not connect all shards")
	}

	edgeExists := make(map[[2]uint64]bool)
	for _, edge := range edges {
		edgeExists[edgeKey(edge.U, edge.V)] = true
	}

	overlay, err := newOverlay(n, edges)
	if err != nil {
		return nil, err
	}

	if mode == OverlayBuildTreeOnly {
		return overlay, nil
	}
	if mode != OverlayBuildFull {
		return nil, errors.New("unknown overlay build mode")
	}

	for {
		bestGain := int64(0)
		bestEdge := OverlayEdge{}

		for _, pair := range pairs {
			key := edgeKey(pair.u, pair.v)
			if edgeExists[key] {
				continue
			}
			if degrees[pair.u] >= degreeLimits[pair.u] || degrees[pair.v] >= degreeLimits[pair.v] {
				continue
			}

			gain := overlayGain(weights, overlay.Dist, pair.u, pair.v)
			if gain > bestGain || (gain == bestGain && gain > 0 && lessEdge(pair.u, pair.v, bestEdge.U, bestEdge.V)) {
				bestGain = gain
				bestEdge = OverlayEdge{U: pair.u, V: pair.v}
			}
		}

		if bestGain <= 0 {
			break
		}

		edges = append(edges, bestEdge)
		edgeExists[edgeKey(bestEdge.U, bestEdge.V)] = true
		degrees[bestEdge.U]++
		degrees[bestEdge.V]++
		overlay, err = newOverlay(n, edges)
		if err != nil {
			return nil, err
		}
	}

	return overlay, nil
}

func (o *Overlay) Route(source, dest uint64) []uint64 {
	if o == nil || source >= o.ShardNum || dest >= o.ShardNum {
		return nil
	}
	route := o.Routes[source][dest]
	if len(route) == 0 {
		return nil
	}
	cp := make([]uint64, len(route))
	copy(cp, route)
	return cp
}

func sortedWeightedPairs(weights [][]int64) []weightedPair {
	n := len(weights)
	pairs := make([]weightedPair, 0, n*(n-1)/2)
	for i := 0; i < n; i++ {
		for j := i + 1; j < n; j++ {
			pairs = append(pairs, weightedPair{u: uint64(i), v: uint64(j), w: weights[i][j]})
		}
	}
	sort.Slice(pairs, func(i, j int) bool {
		if pairs[i].w != pairs[j].w {
			return pairs[i].w > pairs[j].w
		}
		if pairs[i].u != pairs[j].u {
			return pairs[i].u < pairs[j].u
		}
		return pairs[i].v < pairs[j].v
	})
	return pairs
}

func newOverlay(n uint64, edges []OverlayEdge) (*Overlay, error) {
	adj := make([][]uint64, n)
	for _, edge := range edges {
		if edge.U >= n || edge.V >= n || edge.U == edge.V {
			return nil, errors.New("invalid overlay edge")
		}
		adj[edge.U] = append(adj[edge.U], edge.V)
		adj[edge.V] = append(adj[edge.V], edge.U)
	}
	for sid := uint64(0); sid < n; sid++ {
		sort.Slice(adj[sid], func(i, j int) bool {
			return adj[sid][i] < adj[sid][j]
		})
	}

	routes := make([][][]uint64, n)
	dist := make([][]int, n)
	for source := uint64(0); source < n; source++ {
		routes[source] = make([][]uint64, n)
		dist[source] = make([]int, n)
		parent := make([]uint64, n)
		seen := make([]bool, n)
		for i := range parent {
			parent[i] = n
			dist[source][i] = -1
		}
		queue := []uint64{source}
		seen[source] = true
		dist[source][source] = 0

		for len(queue) > 0 {
			cur := queue[0]
			queue = queue[1:]
			for _, next := range adj[cur] {
				if seen[next] {
					continue
				}
				seen[next] = true
				parent[next] = cur
				dist[source][next] = dist[source][cur] + 1
				queue = append(queue, next)
			}
		}

		for dest := uint64(0); dest < n; dest++ {
			if !seen[dest] {
				return nil, errors.New("overlay is disconnected")
			}
			routes[source][dest] = buildRoute(source, dest, parent)
		}
	}

	edgeCopy := make([]OverlayEdge, len(edges))
	copy(edgeCopy, edges)
	return &Overlay{
		ShardNum: n,
		Edges:    edgeCopy,
		Routes:   routes,
		Dist:     dist,
	}, nil
}

func buildRoute(source, dest uint64, parent []uint64) []uint64 {
	if source == dest {
		return []uint64{source}
	}
	route := make([]uint64, 0)
	for cur := dest; cur != source; cur = parent[cur] {
		route = append(route, cur)
	}
	route = append(route, source)
	for i, j := 0, len(route)-1; i < j; i, j = i+1, j-1 {
		route[i], route[j] = route[j], route[i]
	}
	return route
}

func overlayGain(weights [][]int64, dist [][]int, u, v uint64) int64 {
	var gain int64
	n := uint64(len(weights))
	for i := uint64(0); i < n; i++ {
		for j := i + 1; j < n; j++ {
			oldDistance := dist[i][j]
			newDistance := oldDistance
			if dist[i][u] >= 0 && dist[v][j] >= 0 {
				candidate := dist[i][u] + 1 + dist[v][j]
				if candidate < newDistance {
					newDistance = candidate
				}
			}
			if dist[i][v] >= 0 && dist[u][j] >= 0 {
				candidate := dist[i][v] + 1 + dist[u][j]
				if candidate < newDistance {
					newDistance = candidate
				}
			}
			if oldDistance > newDistance {
				gain += weights[i][j] * int64(oldDistance-newDistance)
			}
		}
	}
	return gain
}

func edgeKey(u, v uint64) [2]uint64 {
	if u > v {
		u, v = v, u
	}
	return [2]uint64{u, v}
}

func lessEdge(u1, v1, u2, v2 uint64) bool {
	if u2 == 0 && v2 == 0 {
		return true
	}
	if u1 != u2 {
		return u1 < u2
	}
	return v1 < v2
}
