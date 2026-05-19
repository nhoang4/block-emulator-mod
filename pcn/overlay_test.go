package pcn

import "testing"

func TestBuildOverlayHonorsDegreeLimitsAndRoutes(t *testing.T) {
	weights := [][]int64{
		{0, 10, 4, 2, 1},
		{10, 0, 9, 3, 2},
		{4, 9, 0, 8, 7},
		{2, 3, 8, 0, 6},
		{1, 2, 7, 6, 0},
	}
	degreeLimits := []int{2, 2, 3, 2, 2}

	overlay, err := BuildOverlay(weights, degreeLimits)
	if err != nil {
		t.Fatalf("BuildOverlay failed: %v", err)
	}

	degrees := make([]int, len(degreeLimits))
	for _, edge := range overlay.Edges {
		degrees[edge.U]++
		degrees[edge.V]++
	}
	for sid, degree := range degrees {
		if degree > degreeLimits[sid] {
			t.Fatalf("shard %d degree = %d, want <= %d", sid, degree, degreeLimits[sid])
		}
	}

	for source := uint64(0); source < overlay.ShardNum; source++ {
		for dest := uint64(0); dest < overlay.ShardNum; dest++ {
			route := overlay.Route(source, dest)
			if len(route) == 0 {
				t.Fatalf("missing route from %d to %d", source, dest)
			}
			if route[0] != source || route[len(route)-1] != dest {
				t.Fatalf("bad route from %d to %d: %v", source, dest, route)
			}
		}
	}
}

func TestBuildTreeOverlayStopsAfterSpanningTree(t *testing.T) {
	weights := [][]int64{
		{0, 10, 4, 2, 1},
		{10, 0, 9, 3, 2},
		{4, 9, 0, 8, 7},
		{2, 3, 8, 0, 6},
		{1, 2, 7, 6, 0},
	}
	degreeLimits := []int{4, 4, 4, 4, 4}

	overlay, err := BuildTreeOverlay(weights, degreeLimits)
	if err != nil {
		t.Fatalf("BuildTreeOverlay failed: %v", err)
	}
	if len(overlay.Edges) != len(degreeLimits)-1 {
		t.Fatalf("tree overlay edges = %d, want %d", len(overlay.Edges), len(degreeLimits)-1)
	}

	for source := uint64(0); source < overlay.ShardNum; source++ {
		for dest := uint64(0); dest < overlay.ShardNum; dest++ {
			route := overlay.Route(source, dest)
			if len(route) == 0 {
				t.Fatalf("missing route from %d to %d", source, dest)
			}
		}
	}
}

func TestBuildBinaryTreeOverlayUsesHeapTopology(t *testing.T) {
	overlay, err := BuildBinaryTreeOverlay(7)
	if err != nil {
		t.Fatalf("BuildBinaryTreeOverlay failed: %v", err)
	}

	wantEdges := []OverlayEdge{
		{U: 0, V: 1},
		{U: 0, V: 2},
		{U: 1, V: 3},
		{U: 1, V: 4},
		{U: 2, V: 5},
		{U: 2, V: 6},
	}
	if len(overlay.Edges) != len(wantEdges) {
		t.Fatalf("binary tree edges = %d, want %d", len(overlay.Edges), len(wantEdges))
	}
	for i, want := range wantEdges {
		if overlay.Edges[i] != want {
			t.Fatalf("binary tree edge %d = %+v, want %+v", i, overlay.Edges[i], want)
		}
	}

	route := overlay.Route(3, 6)
	wantRoute := []uint64{3, 1, 0, 2, 6}
	if len(route) != len(wantRoute) {
		t.Fatalf("route 3->6 = %v, want %v", route, wantRoute)
	}
	for i := range wantRoute {
		if route[i] != wantRoute[i] {
			t.Fatalf("route 3->6 = %v, want %v", route, wantRoute)
		}
	}
}

func TestCompleteOverlayUsesDirectRoutes(t *testing.T) {
	overlay := NewCompleteOverlay(4)
	route := overlay.Route(0, 3)
	if len(route) != 2 || route[0] != 0 || route[1] != 3 {
		t.Fatalf("complete overlay route 0->3 = %v, want [0 3]", route)
	}
}
