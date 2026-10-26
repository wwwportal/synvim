local M = {}

-- ==============================================================================
-- CP-Algorithms (e-maxx-eng) & NIST DADS (Dictionary of Algorithms and Data
-- Structures) Embedded Catalog + Live Article Fetcher
-- ==============================================================================
-- Each entry maps directly to its canonical CP-Algorithms source path
-- (`https://raw.githubusercontent.com/cp-algorithms/cp-algorithms/main/src/<cp_path>`)
-- and/or NIST DADS entry (`https://xlinux.nist.gov/dads/HTML/<nist>.html`),
-- alongside offline complexity bounds, core structural invariants, and
-- language-agnostic pseudocode.

M.CATALOG = {
  -- ── 1. Trees, Range Queries & Disjoint Sets ──────────────────────────────
  {
    id = "fenwick-tree",
    name = "Fenwick Tree (Binary Indexed Tree / BIT)",
    category = "Data Structures / Trees",
    cp_path = "data_structures/fenwick.md",
    nist = "binaryIndexedTree",
    keywords = "fenwick bit binary indexed tree prefix sum point update range query lsb lowbit",
    complexity = "Time: O(log n) update & prefix query, O(n) build | Space: O(n)",
    invariant = "bit[i] stores the aggregate over the half-open interval (i - lsb(i), i] where lsb(i) = i & (-i).",
    pseudocode = {
      "function add(idx, val):                 -- 1-based index",
      "  while idx <= N:",
      "    bit[idx] <- bit[idx] + val",
      "    idx <- idx + (idx & -idx)           -- jump to parent covering range",
      "",
      "function prefix_sum(idx):",
      "  res <- 0",
      "  while idx > 0:",
      "    res <- res + bit[idx]",
      "    idx <- idx - (idx & -idx)           -- strip lowest set bit",
      "  return res",
    },
  },
  {
    id = "segment-tree",
    name = "Segment Tree (with Lazy Propagation)",
    category = "Data Structures / Trees",
    cp_path = "data_structures/segment_tree.md",
    nist = "segmentTree",
    keywords = "segment tree segtree lazy propagation range update range query monoid associative",
    complexity = "Time: O(n) build, O(log n) range query & range update | Space: O(4n)",
    invariant = "Node v covering [tl, tr] holds associative merge(left(2v), right(2v+1)) plus pending lazy tag for descendants.",
    pseudocode = {
      "function query(v, tl, tr, l, r):",
      "  if l > r: return IDENTITY",
      "  if l == tl and r == tr: return tree[v]",
      "  push_lazy(v, tl, tr)",
      "  tm <- (tl + tr) // 2",
      "  return combine(query(2*v, tl, tm, l, min(r, tm)),",
      "                 query(2*v+1, tm+1, tr, max(l, tm+1), r))",
    },
  },
  {
    id = "persistent-segment-tree",
    name = "Persistent Segment Tree (Path Copying)",
    category = "Data Structures / Persistent",
    cp_path = "data_structures/segment_tree.md",
    nist = "persistentDataStructure",
    keywords = "persistent segment tree functional path copying version history kth order statistic",
    complexity = "Time: O(log n) per update/query | Space: O(n + q log n)",
    invariant = "Each point update allocates O(log n) new nodes along the root-to-leaf path while sharing unmodified subtrees.",
    pseudocode = {
      "function update(node, tl, tr, pos, val):",
      "  if tl == tr: return new_leaf(val)",
      "  tm <- (tl + tr) // 2",
      "  if pos <= tm:",
      "    return new_node(update(node.left, tl, tm, pos, val), node.right)",
      "  else:",
      "    return new_node(node.left, update(node.right, tm+1, tr, pos, val))",
    },
  },
  {
    id = "disjoint-set-union",
    name = "Disjoint Set Union (DSU / Union-Find)",
    category = "Data Structures / Sets",
    cp_path = "data_structures/disjoint_set_union.md",
    nist = "disjointSet",
    keywords = "dsu union find disjoint set path compression union by rank size connected components",
    complexity = "Time: O(alpha(n)) amortized per find/union | Space: O(n)",
    invariant = "Every element points toward its set representative root; rank/size strictly increases along parent pointers.",
    pseudocode = {
      "function find_set(v):",
      "  if v == parent[v]: return v",
      "  parent[v] <- find_set(parent[v])      -- path compression",
      "  return parent[v]",
      "",
      "function union_sets(a, b):",
      "  a <- find_set(a); b <- find_set(b)",
      "  if a != b:",
      "    if size[a] < size[b]: swap(a, b)    -- union by size",
      "    parent[b] <- a; size[a] <- size[a] + size[b]",
    },
  },
  {
    id = "treap",
    name = "Treap (Cartesian Tree / Randomized BST & Implicit Treap)",
    category = "Data Structures / Trees",
    cp_path = "data_structures/treap.md",
    nist = "treap",
    keywords = "treap cartesian tree split merge randomized bst implicit treap rope array",
    complexity = "Time: O(log n) expected split, merge, insert, erase | Space: O(n)",
    invariant = "Simultaneously satisfies BST ordering on keys (left.key < node.key < right.key) and max-heap ordering on random priorities.",
    pseudocode = {
      "function split(t, key) -> (L, R):",
      "  if t == nil: return (nil, nil)",
      "  if t.key <= key:",
      "    (t.right, R) <- split(t.right, key); update(t); return (t, R)",
      "  else:",
      "    (L, t.left) <- split(t.left, key); update(t); return (L, t)",
      "",
      "function merge(L, R) -> T:",
      "  if L == nil or R == nil: return L or R",
      "  if L.prio > R.prio: L.right <- merge(L.right, R); update(L); return L",
      "  else:               R.left  <- merge(L, R.left);  update(R); return R",
    },
  },
  {
    id = "sparse-table",
    name = "Sparse Table (O(1) Range Minimum Query / Idempotent RMQ)",
    category = "Data Structures / Range Queries",
    cp_path = "data_structures/sparse-table.md",
    nist = "rangeMinimumQuery",
    keywords = "sparse table rmq range minimum query idempotent lca static",
    complexity = "Time: O(n log n) build, O(1) idempotent query (min/max/gcd) | Space: O(n log n)",
    invariant = "st[k][i] stores the aggregate over the interval [i, i + 2^k - 1] of length 2^k.",
    pseudocode = {
      "for i in 0 .. N-1: st[0][i] <- arr[i]",
      "for k in 1 .. LOGN:",
      "  for i in 0 .. N - (1 << k):",
      "    st[k][i] <- min(st[k-1][i], st[k-1][i + (1 << (k-1))])",
      "",
      "function query_min(L, R):",
      "  k <- floor_log2(R - L + 1)",
      "  return min(st[k][L], st[k][R - (1 << k) + 1])",
    },
  },
  {
    id = "sqrt-decomposition",
    name = "Sqrt Decomposition & Mo's Algorithm",
    category = "Data Structures / Range Queries",
    cp_path = "data_structures/sqrt_decomposition.md",
    nist = "sqrtDecomposition",
    keywords = "sqrt decomposition square root block mo algorithm offline range queries",
    complexity = "Time: O(sqrt(n)) per query/update; Mo's offline: O((n + q) sqrt(n)) | Space: O(n)",
    invariant = "Array of size n is partitioned into blocks of size B ≈ sqrt(n); offline queries sorted by (L // B, R).",
    pseudocode = {
      "-- Mo's Offline Query Ordering:",
      "sort queries by (q.L // B, q.R if (q.L // B) is even else -q.R)",
      "curL <- 0; curR <- -1",
      "for q in queries:",
      "  while curL > q.L: curL <- curL - 1; add(curL)",
      "  while curR < q.R: curR <- curR + 1; add(curR)",
      "  while curL < q.L: remove(curL); curL <- curL + 1",
      "  while curR > q.R: remove(curR); curR <- curR - 1",
      "  ans[q.id] <- current_answer()",
    },
  },
  {
    id = "red-black-tree",
    name = "Red-Black Tree (Balanced Binary Search Tree)",
    category = "Data Structures / Balanced Trees (NIST DADS)",
    cp_path = "data_structures/treap.md",
    nist = "redblack",
    keywords = "red black tree rbtree balanced bst rotation black height std map set",
    complexity = "Time: O(log n) worst-case search, insert, delete (<= 3 rotations) | Space: O(n)",
    invariant = "1) Root & leaves are black; 2) Red nodes have black children; 3) All paths from any node to NIL have equal black-height.",
    pseudocode = {
      "function insert_fixup(z):",
      "  while z.parent.color == RED:",
      "    uncle <- sibling(z.parent)",
      "    if uncle.color == RED:              -- Case 1: recolor parent, uncle, grandparent",
      "      z.parent.color <- BLACK; uncle.color <- BLACK",
      "      z.grandparent.color <- RED; z <- z.grandparent",
      "    else:                               -- Case 2 & 3: zig-zag / zig-zig rotation",
      "      if z is inner grandchild: rotate(z.parent)",
      "      z.parent.color <- BLACK; z.grandparent.color <- RED",
      "      rotate(z.grandparent)",
      "  root.color <- BLACK",
    },
  },
  {
    id = "b-tree",
    name = "B-Tree & B+ Tree (External / Database Index Tree)",
    category = "Data Structures / Indexing (NIST DADS)",
    cp_path = "data_structures/treap.md",
    nist = "btree",
    keywords = "btree b+tree database index page disk block branching factor split merge",
    complexity = "Time: O(log_B n) I/O page reads for search, insert, range scan | Space: O(n)",
    invariant = "Every internal node (except root) has between t and 2t children ([t-1, 2t-1] keys), and all leaves lie at the exact same depth.",
    pseudocode = {
      "function btree_insert(root, key):",
      "  if root.num_keys == 2*t - 1:",
      "    s <- allocate_node(is_leaf = false)",
      "    s.children[0] <- root",
      "    split_child(s, 0, root)",
      "    insert_nonfull(s, key)",
      "    return s",
      "  else:",
      "    insert_nonfull(root, key); return root",
    },
  },
  {
    id = "skip-list",
    name = "Skip List (Probabilistic Multi-Level Linked List)",
    category = "Data Structures / Probabilistic (NIST DADS)",
    cp_path = "data_structures/treap.md",
    nist = "skiplist",
    keywords = "skip list skiplist probabilistic express lane level concurrent sorted set",
    complexity = "Time: O(log n) expected search, insert, delete | Space: O(n) expected",
    invariant = "Level k+1 is a sparse subsequence of Level k where each node is promoted to the next level with probability p (typically 1/2 or 1/4).",
    pseudocode = {
      "function search(target):",
      "  curr <- head",
      "  for lvl from MAX_LEVEL down to 0:",
      "    while curr.next[lvl] != nil and curr.next[lvl].key < target:",
      "      curr <- curr.next[lvl]",
      "  curr <- curr.next[0]",
      "  return (curr != nil and curr.key == target) ? curr : nil",
    },
  },
  {
    id = "bloom-filter",
    name = "Bloom Filter (Probabilistic Set Membership)",
    category = "Data Structures / Probabilistic (NIST DADS)",
    cp_path = "string/string-hashing.md",
    nist = "bloomFilter",
    keywords = "bloom filter bit array hash functions false positive membership approximate",
    complexity = "Time: O(k) insert & lookup (k hash functions) | Space: m bits (≈ 1.44 log2(1/eps) bits per key)",
    invariant = "Zero false negatives: if any of bits[h_i(x) mod m] is 0, x is definitely not in S; false positive rate ≈ (1 - e^(-kn/m))^k.",
    pseudocode = {
      "function add(x):",
      "  for i in 1 .. k:",
      "    bits[hash_i(x) mod m] <- 1",
      "",
      "function possibly_contains(x):",
      "  for i in 1 .. k:",
      "    if bits[hash_i(x) mod m] == 0: return false",
      "  return true",
    },
  },
  {
    id = "lru-cache",
    name = "LRU Cache (Least Recently Used Eviction Table)",
    category = "Data Structures / Caching",
    cp_path = "string/string-hashing.md",
    nist = "dictionary",
    keywords = "lru cache least recently used doubly linked list hash map eviction o(1)",
    complexity = "Time: O(1) get and put | Space: O(capacity)",
    invariant = "Hash map maps key -> node in a doubly-linked list ordered from Most Recently Used (head) to Least Recently Used (tail).",
    pseudocode = {
      "function get(key):",
      "  if key not in map: return nil",
      "  node <- map[key]; move_to_front(list, node)",
      "  return node.value",
      "",
      "function put(key, val):",
      "  if key in map: node <- map[key]; node.val <- val; move_to_front(list, node)",
      "  else:",
      "    if size == capacity: evicted <- pop_back(list); delete map[evicted.key]",
      "    map[key] <- push_front(list, new_node(key, val))",
    },
  },

  -- ── 2. Graph Search, Shortest Paths, Connectivity & Flows ────────────────
  {
    id = "dijkstra",
    name = "Dijkstra's Shortest Path Algorithm (Non-Negative Weights)",
    category = "Graphs / Shortest Paths",
    cp_path = "graph/dijkstra_sparse.md",
    nist = "dijkstra",
    keywords = "dijkstra shortest path priority queue min heap single source non-negative",
    complexity = "Time: O((V + E) log V) with binary heap, O(E + V log V) with Fibonacci heap | Space: O(V + E)",
    invariant = "When vertex u is popped from the min-heap with dist[u] == d, dist[u] is optimal because all edge weights w >= 0.",
    pseudocode = {
      "dist[*] <- +INF; dist[src] <- 0",
      "pq.push((0, src))",
      "while not pq.empty():",
      "  (d, u) <- pq.pop_min()",
      "  if d > dist[u]: continue",
      "  for (v, w) in adj[u]:",
      "    if dist[u] + w < dist[v]:",
      "      dist[v] <- dist[u] + w; parent[v] <- u",
      "      pq.push((dist[v], v))",
    },
  },
  {
    id = "bellman-ford",
    name = "Bellman-Ford & SPFA (Negative Weights & Negative Cycle Detection)",
    category = "Graphs / Shortest Paths",
    cp_path = "graph/bellman_ford.md",
    nist = "bellmanFord",
    keywords = "bellman ford spfa negative weight cycle shortest path relaxation",
    complexity = "Time: O(V * E) worst-case | Space: O(V)",
    invariant = "After k phases of relaxing all edges, dist[v] is at most the shortest walk from src to v using <= k edges; a change on phase V proves a negative cycle.",
    pseudocode = {
      "dist[*] <- +INF; dist[src] <- 0",
      "for phase in 1 .. V:",
      "  changed <- false",
      "  for (u, v, w) in edges:",
      "    if dist[u] < +INF and dist[u] + w < dist[v]:",
      "      dist[v] <- dist[u] + w; changed <- true",
      "      if phase == V: return NEGATIVE_CYCLE_DETECTED",
      "  if not changed: break",
    },
  },
  {
    id = "floyd-warshall",
    name = "Floyd-Warshall All-Pairs Shortest Paths (APSP)",
    category = "Graphs / Shortest Paths",
    cp_path = "graph/all-pair-shortest-path-floyd-warshall.md",
    nist = "floydWarshall",
    keywords = "floyd warshall all pairs shortest path apsp dynamic programming transitive closure",
    complexity = "Time: O(V^3) | Space: O(V^2)",
    invariant = "After outer iteration k, d[i][j] holds the shortest path from i to j using only intermediate vertices from {1..k}.",
    pseudocode = {
      "for k in 1 .. V:",
      "  for i in 1 .. V:",
      "    for j in 1 .. V:",
      "      if d[i][k] < +INF and d[k][j] < +INF:",
      "        d[i][j] <- min(d[i][j], d[i][k] + d[k][j])",
    },
  },
  {
    id = "tarjan-scc",
    name = "Tarjan's & Kosaraju's Strongly Connected Components (SCC)",
    category = "Graphs / Connectivity",
    cp_path = "graph/strongly-connected-components.md",
    nist = "tarjansStronglyConnected",
    keywords = "tarjan kosaraju scc strongly connected components lowlink condensation dag",
    complexity = "Time: O(V + E) single DFS pass | Space: O(V)",
    invariant = "Vertex u is the root of an SCC iff low[u] == tin[u] after exploring all descendants; active vertices of that SCC sit above u on the stack.",
    pseudocode = {
      "function dfs(u):",
      "  tin[u] <- low[u] <- ++timer",
      "  stack.push(u); on_stack[u] <- true",
      "  for v in adj[u]:",
      "    if tin[v] == 0: dfs(v); low[u] <- min(low[u], low[v])",
      "    else if on_stack[v]:    low[u] <- min(low[u], tin[v])",
      "  if low[u] == tin[u]:                  -- u is root of SCC",
      "    repeat: w <- stack.pop(); on_stack[w] <- false; scc[w] <- u until w == u",
    },
  },
  {
    id = "bridges-and-cutpoints",
    name = "Bridges & Articulation Points (Cut Vertices) in O(V + E)",
    category = "Graphs / Connectivity",
    cp_path = "graph/bridge-searching.md",
    nist = "biconnectedComponent",
    keywords = "bridge cut edge articulation point cutpoint biconnected lowlink dfs tree",
    complexity = "Time: O(V + E) | Space: O(V)",
    invariant = "Tree edge (u, v) is a bridge iff low[v] > tin[u]; u is a cutpoint iff low[v] >= tin[u] (or root with >= 2 DFS children).",
    pseudocode = {
      "function dfs(u, p):",
      "  tin[u] <- low[u] <- ++timer",
      "  for v in adj[u]:",
      "    if v == p: continue",
      "    if tin[v] != 0: low[u] <- min(low[u], tin[v])",
      "    else:",
      "      dfs(v, u); low[u] <- min(low[u], low[v])",
      "      if low[v] > tin[u]: report_bridge(u, v)",
    },
  },
  {
    id = "kruskal-prim-mst",
    name = "Minimum Spanning Tree (Kruskal's & Prim's Algorithms)",
    category = "Graphs / Spanning Trees",
    cp_path = "graph/mst_kruskal.md",
    nist = "kruskals",
    keywords = "mst minimum spanning tree kruskal prim greedy cut property dsu",
    complexity = "Time: O(E log E) Kruskal | Space: O(V + E)",
    invariant = "Cut Property: the lightest edge crossing any cut of V belongs to some Minimum Spanning Tree.",
    pseudocode = {
      "sort edges by weight w ascending",
      "mst_cost <- 0",
      "for (u, v, w) in edges:",
      "  if dsu.find(u) != dsu.find(v):",
      "    dsu.union(u, v)",
      "    mst_cost <- mst_cost + w",
      "    mst_edges.push((u, v))",
    },
  },
  {
    id = "lca-binary-lifting",
    name = "Lowest Common Ancestor (LCA via Binary Lifting & Euler Tour RMQ)",
    category = "Graphs / Trees",
    cp_path = "graph/lca_binary_lifting.md",
    nist = "lowestCommonAncestor",
    keywords = "lca lowest common ancestor binary lifting euler tour tree distance ancestor",
    complexity = "Time: O(N log N) preprocess, O(log N) per query (or O(1) with Farach-Colton/RMQ) | Space: O(N log N)",
    invariant = "up[u][k] stores the 2^k-th ancestor of u; u is an ancestor of v iff tin[u] <= tin[v] and tout[u] >= tout[v].",
    pseudocode = {
      "function is_ancestor(u, v): return tin[u] <= tin[v] and tout[u] >= tout[v]",
      "function lca(u, v):",
      "  if is_ancestor(u, v): return u",
      "  if is_ancestor(v, u): return v",
      "  for k from LOGN down to 0:",
      "    if not is_ancestor(up[u][k], v):",
      "      u <- up[u][k]",
      "  return up[u][0]",
    },
  },
  {
    id = "heavy-light-decomposition",
    name = "Heavy-Light Decomposition (HLD for Tree Path Queries)",
    category = "Graphs / Trees",
    cp_path = "graph/hld.md",
    nist = "tree",
    keywords = "hld heavy light decomposition tree path query segment tree subtree",
    complexity = "Time: O(N) build, O(log^2 N) path query with Segment Tree | Space: O(N)",
    invariant = "Each vertex picks its largest-subtree child as its heavy child; any root-to-node path crosses at most log2(N) light edges.",
    pseudocode = {
      "function query_path(u, v):",
      "  res <- IDENTITY",
      "  while head[u] != head[v]:",
      "    if depth[head[u]] < depth[head[v]]: swap(u, v)",
      "    res <- combine(res, segtree.query(pos[head[u]], pos[u]))",
      "    u <- parent[head[u]]",
      "  if depth[u] > depth[v]: swap(u, v)",
      "  return combine(res, segtree.query(pos[u], pos[v]))",
    },
  },
  {
    id = "dinic-max-flow",
    name = "Dinic's Maximum Flow & Min-Cut Algorithm",
    category = "Graphs / Flows & Matching",
    cp_path = "graph/dinic.md",
    nist = "dinics",
    keywords = "dinic max flow min cut blocking flow level graph bipartite matching unit network",
    complexity = "Time: O(V^2 E) general, O(E sqrt(V)) unit networks / bipartite matching | Space: O(V + E)",
    invariant = "Each phase builds a shortest-path BFS level graph and pushes a blocking flow via DFS with current-arc pointers `ptr[u]`; shortest s-t distance strictly increases every phase.",
    pseudocode = {
      "flow <- 0",
      "while bfs_build_levels(S, T):           -- level[v] = level[u] + 1 on residual edges",
      "  ptr[*] <- 0",
      "  while (pushed <- dfs_blocking(S, +INF)) > 0:",
      "    flow <- flow + pushed",
      "return flow",
    },
  },

  -- ── 3. Strings, Pattern Matching & Automata ──────────────────────────────
  {
    id = "kmp-prefix-function",
    name = "Knuth-Morris-Pratt (KMP) & Prefix Function",
    category = "Strings / Pattern Matching",
    cp_path = "string/prefix-function.md",
    nist = "knuthMorrisPratt",
    keywords = "kmp knuth morris pratt prefix function border failure link string matching",
    complexity = "Time: O(n + m) linear time | Space: O(m)",
    invariant = "pi[i] is the length of the longest proper prefix of s[0..i] that is also a suffix of s[0..i].",
    pseudocode = {
      "pi[0] <- 0",
      "for i in 1 .. n-1:",
      "  j <- pi[i-1]",
      "  while j > 0 and s[i] != s[j]: j <- pi[j-1]",
      "  if s[i] == s[j]: j <- j + 1",
      "  pi[i] <- j",
    },
  },
  {
    id = "z-algorithm",
    name = "Z-Function (Linear-Time Longest Common Prefix Array)",
    category = "Strings / Pattern Matching",
    cp_path = "string/z-function.md",
    nist = "stringMatching",
    keywords = "z function z algorithm lcp prefix substring matching z-box",
    complexity = "Time: O(n) | Space: O(n)",
    invariant = "z[i] = LCP(s, s[i..n-1]); maintains rightmost matched Z-box [l, r] so r only advances monotonically.",
    pseudocode = {
      "l <- 0; r <- 0",
      "for i in 1 .. n-1:",
      "  if i < r: z[i] <- min(r - i, z[i - l])",
      "  while i + z[i] < n and s[z[i]] == s[i + z[i]]:",
      "    z[i] <- z[i] + 1",
      "  if i + z[i] > r: l <- i; r <- i + z[i]",
    },
  },
  {
    id = "aho-corasick",
    name = "Aho-Corasick Multi-Pattern Automaton",
    category = "Strings / Automata",
    cp_path = "string/aho_corasick.md",
    nist = "ahoCorasick",
    keywords = "aho corasick trie suffix link dictionary automaton multi pattern matching",
    complexity = "Time: O(sum(|P_i|) * |Sigma|) build, O(|T| + matches) scan | Space: O(sum(|P_i|) * |Sigma|)",
    invariant = "Each trie state u has a suffix link `link[u]` pointing to the longest proper suffix of u present in the trie, computed via BFS.",
    pseudocode = {
      "queue <- [root]",
      "while not queue.empty():",
      "  u <- queue.pop()",
      "  for c in alphabet:",
      "    if next[u][c] exists:",
      "      link[next[u][c]] <- (u == root) ? root : next[link[u]][c]",
      "      queue.push(next[u][c])",
      "    else:",
      "      next[u][c] <- next[link[u]][c]",
    },
  },
  {
    id = "suffix-automaton",
    name = "Suffix Automaton (SAM — Minimal DAWG of All Substrings)",
    category = "Strings / Automata",
    cp_path = "string/suffix-automaton.md",
    nist = "directedAcyclicWordGraph",
    keywords = "suffix automaton sam endpos dawg substrings lcs distinct substrings",
    complexity = "Time: O(n) online construction | Space: <= 2n - 1 states and <= 3n - 4 transitions",
    invariant = "States partition all substrings of S into `endpos`-equivalence classes; suffix links form a tree nesting endpos sets.",
    pseudocode = {
      "function sam_extend(c):",
      "  cur <- new_state(len = st[last].len + 1); p <- last",
      "  while p != -1 and not st[p].next[c]: st[p].next[c] <- cur; p <- st[p].link",
      "  if p == -1: st[cur].link <- 0",
      "  else:",
      "    q <- st[p].next[c]",
      "    if st[p].len + 1 == st[q].len: st[cur].link <- q",
      "    else: clone <- clone_state(q, len = st[p].len + 1); redirect p.. to clone",
      "  last <- cur",
    },
  },
  {
    id = "suffix-array-kasai",
    name = "Suffix Array & Kasai's LCP Array",
    category = "Strings / Indexing",
    cp_path = "string/suffix-array.md",
    nist = "suffixArray",
    keywords = "suffix array lcp kasai SA-IS burrows wheeler bwt fm-index substring search",
    complexity = "Time: O(n log n) cyclic doubling (or O(n) SA-IS), O(n) Kasai LCP | Space: O(n)",
    invariant = "SA[i] is the starting index of the i-th lexicographically smallest suffix; lcp[i] = LCP(S[SA[i]..], S[SA[i+1]..]) satisfies lcp[rank[i]] >= lcp[rank[i-1]] - 1.",
    pseudocode = {
      "-- Kasai's O(n) LCP construction from Suffix Array SA:",
      "k <- 0",
      "for i in 0 .. n-1:",
      "  if rank[i] == n - 1: k <- 0; continue",
      "  j <- SA[rank[i] + 1]",
      "  while i + k < n and j + k < n and S[i+k] == S[j+k]: k <- k + 1",
      "  lcp[rank[i]] <- k",
      "  if k > 0: k <- k - 1",
    },
  },

  -- ── 4. Information Retrieval, Fuzzy Alignment & Diff Algorithms ──────────
  {
    id = "smith-waterman-fzf",
    name = "Smith-Waterman Local Sequence Alignment (FZF Affine-Gap Fuzzy Scoring)",
    category = "Information Retrieval & Alignment",
    cp_path = "dynamic_programming/profile-dynamics.md",
    nist = "smithWaterman",
    keywords = "smith waterman fzf fuzzy subsequence alignment affine gap edit distance dynamic programming",
    complexity = "Time: O(|P| * |T|) | Space: O(|T|) rolling rows",
    invariant = "M[i][j] = max score aligning pattern P[1..i] ending at T[j]; G[i][j] = best score with a gap after matching P[1..i].",
    pseudocode = {
      "for i in 1 .. |P|:",
      "  for j in i .. |T|:",
      "    if P[i] == T[j]:",
      "      consec <- (P[i-1] == T[j-1]) ? M[i-1][j-1] + BONUS_CONSEC : 0",
      "      M[i][j] <- max(consec, best_prev[j-1] + boundary_bonus(T, j))",
      "    G[i][j] <- max(M[i][j-1] - GAP_OPEN, G[i][j-1] - GAP_EXTEND)",
    },
  },
  {
    id = "okapi-bm25",
    name = "Okapi BM25 Probabilistic Information Retrieval Ranking",
    category = "Information Retrieval & Search",
    cp_path = "string/string-hashing.md",
    nist = "invertedIndex",
    keywords = "bm25 okapi tf idf inverted index document length normalization search ranking",
    complexity = "Time: O(|Q| * avg_posting_list_len) | Space: O(vocabulary + postings)",
    invariant = "Saturates term frequency with parameter k1 ≈ 1.2 and normalizes document length against corpus mean avgdl with parameter b ≈ 0.75.",
    pseudocode = {
      "IDF(q) = ln(1 + (N - df(q) + 0.5) / (df(q) + 0.5))",
      "for each query term q in Q:",
      "  tf_norm <- (tf(q, D) * (k1 + 1)) / (tf(q, D) + k1 * (1 - b + b * |D| / avgdl))",
      "  score(D, Q) <- score(D, Q) + IDF(q) * tf_norm",
    },
  },
  {
    id = "damerau-levenshtein",
    name = "Damerau-Levenshtein Edit Distance (with Adjacent Transpositions)",
    category = "Strings / Edit Distance (NIST DADS)",
    cp_path = "dynamic_programming/profile-dynamics.md",
    nist = "levenshtein",
    keywords = "levenshtein damerau edit distance typo fuzzy transposition insertion deletion substitution",
    complexity = "Time: O(|A| * |B|) | Space: O(min(|A|, |B|)) with 3 rolling rows",
    invariant = "d[i][j] is the minimum edits (insert, delete, substitute, or transpose adjacent A[i-1..i] == B[j..j-1]) to transform A[1..i] into B[1..j].",
    pseudocode = {
      "d[i][j] <- min(",
      "  d[i-1][j] + 1,                        -- deletion",
      "  d[i][j-1] + 1,                        -- insertion",
      "  d[i-1][j-1] + (A[i] == B[j] ? 0 : 1), -- substitution",
      "  (A[i]==B[j-1] and A[i-1]==B[j]) ? d[i-2][j-2] + 1 : +INF -- transposition",
      ")",
    },
  },

  -- ── 5. Algebra, Number Theory, FFT & Geometry ────────────────────────────
  {
    id = "fast-fourier-transform",
    name = "Fast Fourier Transform (Cooley-Tukey FFT & Number Theoretic Transform NTT)",
    category = "Algebra & Signal Processing",
    cp_path = "algebra/fft.md",
    nist = "fastFourierTransform",
    keywords = "fft ntt fast fourier transform polynomial multiplication convolution roots of unity",
    complexity = "Time: O(n log n) | Space: O(n)",
    invariant = "Splits A(x) = A_even(x^2) + x * A_odd(x^2) and evaluates at n-th roots of unity w_n^k using symmetry w_n^(k + n/2) = -w_n^k.",
    pseudocode = {
      "bit_reverse_permute(a, n)",
      "for len = 2, 4, ..., n:",
      "  wlen <- exp(2*pi*i / len * (invert ? -1 : 1))",
      "  for i = 0, len, 2*len, ...:",
      "    w <- 1",
      "    for j = 0 .. len/2 - 1:",
      "      u <- a[i+j]; v <- a[i+j+len/2] * w",
      "      a[i+j] <- u + v; a[i+j+len/2] <- u - v; w <- w * wlen",
    },
  },
  {
    id = "extended-euclid-crt",
    name = "Extended Euclidean Algorithm, Modular Inverse & Chinese Remainder Theorem",
    category = "Algebra & Number Theory",
    cp_path = "algebra/extended-euclid-algorithm.md",
    nist = "euclids",
    keywords = "extended euclid gcd bezout modular inverse chinese remainder theorem crt",
    complexity = "Time: O(log(min(a, b))) | Space: O(1)",
    invariant = "Maintains Bezout identity a*x + b*y = gcd(a, b) throughout Euclidean division steps.",
    pseudocode = {
      "function ext_gcd(a, b) -> (g, x, y):",
      "  if b == 0: return (a, 1, 0)",
      "  (g, x1, y1) <- ext_gcd(b, a mod b)",
      "  return (g, y1, x1 - (a // b) * y1)",
    },
  },
  {
    id = "convex-hull-monotone-chain",
    name = "Convex Hull (Andrew's Monotone Chain & Graham Scan)",
    category = "Computational Geometry",
    cp_path = "geometry/convex-hull.md",
    nist = "convexHull",
    keywords = "convex hull monotone chain graham scan cross product orientation ccw geometry",
    complexity = "Time: O(n log n) | Space: O(n)",
    invariant = "Upper and lower hulls maintain strictly counter-clockwise (CCW) turns: cross(H[#H-1] - H[#H-2], pt - H[#H-2]) > 0.",
    pseudocode = {
      "sort points P by (x, y) ascending",
      "for pt in P:                            -- lower hull",
      "  while #H >= 2 and cross(H[#H-1] - H[#H-2], pt - H[#H-2]) <= 0:",
      "    H.pop()",
      "  H.push(pt)",
      "-- repeat in reverse for upper hull",
    },
  },
  {
    id = "divide-and-conquer-dp-knuth",
    name = "Divide & Conquer DP and Knuth's Quadrangle Inequality Optimization",
    category = "Dynamic Programming Optimizations",
    cp_path = "dynamic_programming/divide-and-conquer-dp.md",
    nist = "dynamicProgramming",
    keywords = "divide and conquer dp knuth optimization quadrangle inequality monotone opt",
    complexity = "Time: Reduces O(k * n^2) to O(k * n log n) (D&C) or O(n^2) (Knuth) | Space: O(k * n)",
    invariant = "Monotonicity of optimal split point opt[i][j] <= opt[i][j+1] (sufficed by Quadrangle Inequality C(a,c) + C(b,d) <= C(a,d) + C(b,c)).",
    pseudocode = {
      "function compute_row(j_left, j_right, opt_left, opt_right):",
      "  if j_left > j_right: return",
      "  mid <- (j_left + j_right) // 2",
      "  best_cost <- +INF; best_k <- opt_left",
      "  for k in opt_left .. min(mid, opt_right):",
      "    if dp_prev[k-1] + cost(k, mid) < best_cost:",
      "      best_cost <- dp_prev[k-1] + cost(k, mid); best_k <- k",
      "  dp_cur[mid] <- best_cost",
      "  compute_row(j_left, mid - 1, opt_left, best_k)",
      "  compute_row(mid + 1, j_right, best_k, opt_right)",
    },
  },
  {
    id = "cuckoo-hashing",
    name = "Cuckoo Hashing (Worst-Case O(1) Lookup Table)",
    category = "Data Structures / Hashing (NIST DADS)",
    cp_path = "string/string-hashing.md",
    nist = "cuckooHashing",
    keywords = "cuckoo hashing hash table constant lookup kick evict cycle stash",
    complexity = "Time: O(1) worst-case lookup & delete, O(1) amortized insert | Space: O(n)",
    invariant = "Key x is stored in either T1[h1(x)] or T2[h2(x)]; collisions displace resident keys until an empty slot is found or rehash triggered.",
    pseudocode = {
      "function lookup(k): return (T1[h1(k)] == k) or (T2[h2(k)] == k)",
      "function insert(k):",
      "  cur <- k",
      "  for step in 1 .. MAX_KICKS:",
      "    swap(cur, T1[h1(cur)])",
      "    if cur == nil: return true",
      "    swap(cur, T2[h2(cur)])",
      "    if cur == nil: return true",
      "  rehash_all()                         -- cycle detected, pick new hash functions",
    },
  },
  {
    id = "hyperloglog",
    name = "HyperLogLog (Sub-Linear Cardinality Estimation / Distinct Counting)",
    category = "Data Structures / Probabilistic Sketches",
    cp_path = "string/string-hashing.md",
    nist = "probabilisticCounting",
    keywords = "hyperloglog hll cardinality distinct count stream leading zeros harmonic mean",
    complexity = "Time: O(1) add | Space: O(m) bytes (m = 2^b registers, relative error ≈ 1.04 / sqrt(m))",
    invariant = "Estimates cardinality n via harmonic mean of 2^(leading zeros of hash(x)) across m independent hash buckets.",
    pseudocode = {
      "function add(x):",
      "  val <- hash64(x)",
      "  bucket <- val & (m - 1)",
      "  w <- val >> b",
      "  M[bucket] <- max(M[bucket], count_leading_zeros(w) + 1)",
      "",
      "function count() -> N:",
      "  Z <- 1.0 / sum(2^(-M[j]) for j in 0..m-1)",
      "  return alpha_m * m * m * Z",
    },
  },
  {
    id = "count-min-sketch",
    name = "Count-Min Sketch (Sub-Linear Frequency Estimation)",
    category = "Data Structures / Probabilistic Sketches",
    cp_path = "string/string-hashing.md",
    nist = "countMinSketch",
    keywords = "count min sketch frequency heavy hitters stream point query inner product",
    complexity = "Time: O(d) update & query (d rows, w columns) | Space: O(w * d)",
    invariant = "Query returns min_{1<=i<=d} count[i][h_i(x)]; guarantees count(x) <= true_freq(x) + eps * ||A||_1 with probability 1 - delta.",
    pseudocode = {
      "function add(x, delta):",
      "  for i in 1 .. d:",
      "    table[i][hash_i(x) mod w] <- table[i][hash_i(x) mod w] + delta",
      "",
      "function estimate(x) -> int:",
      "  return min(table[i][hash_i(x) mod w] for i in 1..d)",
    },
  },
  {
    id = "fibonacci-heap",
    name = "Fibonacci Heap (Amortized O(1) Decrease-Key Priority Queue)",
    category = "Data Structures / Heaps (NIST DADS)",
    cp_path = "graph/dijkstra_sparse.md",
    nist = "fibonacciHeap",
    keywords = "fibonacci heap priority queue decrease key min heap amortized cascading cut",
    complexity = "Time: O(1) amortized insert, minimum, union, decrease-key; O(log n) extract-min | Space: O(n)",
    invariant = "Trees are root-degree-ordered; cascading cuts guarantee degree of root of size k is at most O(log n) using Fibonacci bound.",
    pseudocode = {
      "function decrease_key(x, new_k):",
      "  x.key <- new_k; p <- x.parent",
      "  if p != nil and x.key < p.key:",
      "    cut(x, p)",
      "    cascading_cut(p)",
      "  if x.key < min_node.key: min_node <- x",
    },
  },
  {
    id = "link-cut-tree",
    name = "Link-Cut Tree (Dynamic Trees via Splay Trees)",
    category = "Data Structures / Dynamic Trees (NIST DADS)",
    cp_path = "data_structures/treap.md",
    nist = "splayTree",
    keywords = "link cut tree lct dynamic trees splay preferred path connectivity",
    complexity = "Time: O(log n) amortized per link, cut, access, find-root, path-query | Space: O(n)",
    invariant = "Decomposes a forest into preferred paths represented as auxiliary Splay trees keyed by depth in the represented tree.",
    pseudocode = {
      "function access(u):",
      "  last <- nil; v <- u",
      "  while v != nil:",
      "    splay(v)",
      "    v.right <- last                    -- switch preferred child",
      "    last <- v; v <- v.parent",
      "  splay(u)",
    },
  },
  {
    id = "suffix-tree-ukkonen",
    name = "Suffix Tree (Ukkonen's Online Linear-Time Construction)",
    category = "Strings / Indexing (NIST DADS)",
    cp_path = "string/suffix-tree-ukkonen.md",
    nist = "suffixTree",
    keywords = "suffix tree ukkonen active point remainder suffix link linear time substring",
    complexity = "Time: O(n) linear time | Space: O(n)",
    invariant = "Maintains (active_node, active_edge, active_length) and uses suffix links to insert suffixes across all implicit extensions in amortized O(1) time.",
    pseudocode = {
      "function extend(pos):",
      "  remainder <- remainder + 1; last_created_internal <- nil",
      "  while remainder > 0:",
      "    if active_length == 0: active_edge <- text[pos]",
      "    if active_node.edges[active_edge] does not exist:",
      "      active_node.edges[active_edge] <- new_leaf(pos, +INF)",
      "    else: ... walk edge / split branch and link ...",
      "    remainder <- remainder - 1",
    },
  },
  {
    id = "myers-diff",
    name = "Myers Diff Algorithm (Shortest Edit Script / Longest Common Subsequence)",
    category = "Information Retrieval & Diff (NIST DADS)",
    cp_path = "dynamic_programming/profile-dynamics.md",
    nist = "diff",
    keywords = "myers diff ses lcs shortest edit script git diff v[k] diagonal greedy",
    complexity = "Time: O(n * D) where D is the size of minimum edit script | Space: O(n + D)",
    invariant = "For each edit distance D = 0, 1, 2, ..., finds the furthest-reaching point along each diagonal k = x - y on the edit graph.",
    pseudocode = {
      "V[1] <- 0",
      "for D in 0 .. MAX_D:",
      "  for k in -D, -D+2, ..., D:",
      "    if k == -D or (k != D and V[k-1] < V[k+1]):",
      "      x <- V[k+1]                       -- move down (insertion)",
      "    else:",
      "      x <- V[k-1] + 1                   -- move right (deletion)",
      "    y <- x - k",
      "    while x < N and y < M and A[x+1] == B[y+1]: x <- x+1; y <- y+1 -- snake",
      "    V[k] <- x",
      "    if x >= N and y >= M: return reconstruct_diff()",
    },
  },
  {
    id = "a-star-search",
    name = "A* Search & 0-1 BFS (Heuristic Graph Search)",
    category = "Graphs / Shortest Paths",
    cp_path = "graph/01_bfs.md",
    nist = "aStar",
    keywords = "a* astar heuristic admissible consistent manhattan euclidean 0-1 bfs deque",
    complexity = "Time: O(E) to O(b^d) depending on heuristic accuracy | Space: O(V)",
    invariant = "Pops vertex u minimizing f(u) = g(u) + h(u); guaranteed optimal when heuristic h(u) is admissible (never overestimates remaining cost).",
    pseudocode = {
      "open_set.push((h(start), 0, start))",
      "while not open_set.empty():",
      "  (f, g, u) <- open_set.pop_min()",
      "  if u == goal: return reconstruct_path(u)",
      "  for (v, w) in adj[u]:",
      "    if g + w < g_score[v]:",
      "      g_score[v] <- g + w",
      "      open_set.push((g + w + h(v), g + w, v))",
    },
  },
  {
    id = "topological-sort",
    name = "Topological Sort (Kahn's In-Degree & DFS Post-Order)",
    category = "Graphs / Directed Acyclic Graphs",
    cp_path = "graph/topological-sort.md",
    nist = "topologicalSort",
    keywords = "topological sort toposort dag in-degree kahn dependency resolution cycle detection",
    complexity = "Time: O(V + E) | Space: O(V)",
    invariant = "For every directed edge (u, v), vertex u appears strictly before vertex v in the sorted order; remaining in-degree > 0 proves a cycle.",
    pseudocode = {
      "queue <- [v for v in V if in_degree[v] == 0]",
      "while not queue.empty():",
      "  u <- queue.pop()",
      "  order.push(u)",
      "  for v in adj[u]:",
      "    in_degree[v] <- in_degree[v] - 1",
      "    if in_degree[v] == 0: queue.push(v)",
      "if #order < V: return CYCLE_DETECTED",
    },
  },
  {
    id = "two-sat",
    name = "2-SAT (Boolean Satisfiability in O(V + E) via Implication Graph)",
    category = "Graphs / Satisfiability & Logic",
    cp_path = "graph/2SAT.md",
    nist = "twoSatisfiability",
    keywords = "2-sat 2sat boolean satisfiability implication graph scc tarjan cnf",
    complexity = "Time: O(V + E) linear time | Space: O(V + E)",
    invariant = "Formula is satisfiable iff for every variable x, x and not(x) lie in distinct SCCs of the implication graph (a or b <=> not(a) -> b and not(b) -> a).",
    pseudocode = {
      "-- Clause (x or y) adds edges: not(x) -> y and not(y) -> x",
      "scc_ids <- tarjan_scc(implication_graph)",
      "for i in 1 .. N:",
      "  if scc[x_i] == scc[not_x_i]: return UNSATISFIABLE",
      "  assignment[x_i] <- (scc[x_i] < scc[not_x_i]) -- topological order in DAG",
      "return (SATISFIABLE, assignment)",
    },
  },
  {
    id = "hungarian-algorithm",
    name = "Hungarian Algorithm (Kuhn-Munkres Minimum Weight Bipartite Matching)",
    category = "Graphs / Matching",
    cp_path = "graph/kuhn_maximum_bipartite_matching.md",
    nist = "hungarianMethod",
    keywords = "hungarian kuhn munkres assignment problem min cost maximum weight bipartite matching",
    complexity = "Time: O(V^3) | Space: O(V^2)",
    invariant = "Maintains dual potentials u[i] + v[j] <= cost[i][j]; tight edges with u[i] + v[j] == cost[i][j] form an augmenting equality subgraph.",
    pseudocode = {
      "-- O(V^3) Kuhn-Munkres potential reduction across n stages",
      "for i in 1 .. N:",
      "  augment_matching(i)                  -- update potentials u, v & find 0-slack edge",
    },
  },
  {
    id = "manacher-algorithm",
    name = "Manacher's Algorithm (Linear-Time Longest Palindromic Substrings)",
    category = "Strings / Palindromes",
    cp_path = "string/manacher.md",
    nist = "stringMatching",
    keywords = "manacher palindrome palindromic radius center symmetry linear time",
    complexity = "Time: O(n) linear time | Space: O(n)",
    invariant = "P[i] = radius of longest palindrome centered at i; maintains rightmost palindrome [C - R, C + R] using symmetry P[i] = min(R - i, P[2*C - i]).",
    pseudocode = {
      "C <- 0; R <- 0",
      "for i in 1 .. #T - 1:",
      "  i_mirror <- 2 * C - i",
      "  if R > i: P[i] <- min(R - i, P[i_mirror])",
      "  while T[i + 1 + P[i]] == T[i - 1 - P[i]]: P[i] <- P[i] + 1",
      "  if i + P[i] > R: C <- i; R <- i + P[i]",
    },
  },
  {
    id = "rabin-karp",
    name = "Rabin-Karp Rolling Hash String Search",
    category = "Strings / Hashing",
    cp_path = "string/rabin-karp.md",
    nist = "rabinKarp",
    keywords = "rabin karp rolling hash polynomial hash multiple pattern substring search",
    complexity = "Time: O(n + m) expected, O(n * m) worst case | Space: O(1)",
    invariant = "H(s[i+1..i+m]) = (H(s[i..i+m-1]) - s[i] * p^(m-1)) * p + s[i+m] (mod M) rolled in O(1) time.",
    pseudocode = {
      "p_pow <- p^(m-1) mod M",
      "h_pat <- hash(pattern); h_cur <- hash(text[0..m-1])",
      "for i in 0 .. n - m:",
      "  if h_cur == h_pat and text[i .. i+m-1] == pattern: report_match(i)",
      "  if i < n - m:",
      "    h_cur <- ((h_cur - text[i] * p_pow) * p + text[i+m]) mod M",
    },
  },
}

--- Build the full reference document for an algorithm entry, enriched with live CP-Algorithms Markdown if available
function M.build_virtual_lines(entry, http_get_fn)
  local lines = {
    "# " .. entry.name,
    "",
    "- **Category**: " .. entry.category,
    "- **Complexity**: " .. entry.complexity,
    "- **Core Invariant**: " .. entry.invariant,
    "- **CP-Algorithms Source**: https://cp-algorithms.com/" .. (entry.cp_path:gsub("%.md$", ".html")),
    "- **NIST DADS Reference**: https://xlinux.nist.gov/dads/HTML/" .. (entry.nist or "index") .. ".html",
    "",
    "## Language-Agnostic Pseudocode",
    "```text",
  }
  for _, pl in ipairs(entry.pseudocode or {}) do
    table.insert(lines, pl)
  end
  table.insert(lines, "```")

  -- Optionally append live CP-Algorithms Markdown article if fetched/cached
  if http_get_fn and entry.cp_path then
    local raw_url = "https://raw.githubusercontent.com/cp-algorithms/cp-algorithms/main/src/" .. entry.cp_path
    local md_body = http_get_fn(raw_url, nil, 2)
    if md_body and vim.trim(md_body) ~= "" and not md_body:match("^404:") then
      table.insert(lines, "")
      table.insert(lines, "---")
      table.insert(lines, "## Full CP-Algorithms Article (`" .. entry.cp_path .. "`)")
      table.insert(lines, "")
      for mline in md_body:gmatch("[^\r\n]+") do
        table.insert(lines, mline)
      end
    end
  end

  return lines
end

--- Search the CP-Algorithms & NIST DADS catalog by query (or return full catalog when query is empty)
function M.search(clean_query, http_get_fn)
  local q = vim.trim(clean_query or ""):lower()
  local tokens = {}
  for w in q:gmatch("[%a%d_%-%+]+") do
    if #w >= 2 then table.insert(tokens, w) end
  end

  local scored = {}
  for idx, entry in ipairs(M.CATALOG) do
    local name_low = entry.name:lower()
    local id_low = entry.id:lower()
    local kw_low = (entry.keywords or ""):lower()
    local cat_low = (entry.category or ""):lower()
    local inv_low = (entry.invariant or ""):lower()
    local comp_low = (entry.complexity or ""):lower()

    local score = 0
    if q == "" then
      score = 900 - idx * 5
    else
      if id_low == q or name_low == q then
        score = score + 980
      elseif name_low:find(q, 1, true) or id_low:find(q, 1, true) then
        score = score + 650
      elseif kw_low:find(q, 1, true) then
        score = score + 520
      end

      local matched_tokens = 0
      for _, tok in ipairs(tokens) do
        local tok_hit = false
        if name_low:find(tok, 1, true) or id_low:find(tok, 1, true) then
          score = score + 220
          tok_hit = true
        end
        if kw_low:find(tok, 1, true) then
          score = score + 160
          tok_hit = true
        end
        if cat_low:find(tok, 1, true) then
          score = score + 95
          tok_hit = true
        end
        if inv_low:find(tok, 1, true) or comp_low:find(tok, 1, true) then
          score = score + 75
          tok_hit = true
        end
        if tok_hit then
          matched_tokens = matched_tokens + 1
        end
      end

      if #tokens > 1 and matched_tokens == #tokens then
        score = score + 180
      end
    end

    if score > 0 then
      local p1 = (entry.pseudocode and entry.pseudocode[1]) or ""
      local p2 = (entry.pseudocode and entry.pseudocode[2]) or ""
      local ctx_lines = {
        string.format("%s  [%s]", entry.name, entry.category),
        entry.complexity,
        "Invariant: " .. entry.invariant,
        p1 .. (p2 ~= "" and ("  |  " .. vim.trim(p2)) or ""),
      }

      table.insert(scored, {
        path = "cp-algorithms://" .. entry.cp_path,
        line = 1,
        virtual_cursor_line = 1,
        col = 1,
        action = "navigate",
        match_type = "algo",
        provider = "algo",
        description = string.format("%s — %s", entry.name, entry.complexity),
        score = score,
        is_virtual = true,
        filetype = "markdown",
        context_lines = ctx_lines,
        context_target_idx = 1,
        algo_entry = entry,
        virtual_lines = M.build_virtual_lines(entry, (q ~= "" and #scored < 3) and http_get_fn or nil),
      })
    end
  end

  -- If fewer than 5 matches or query is non-empty, query Wikipedia Computer Science REST API for broader coverage
  if #scored < 5 and q ~= "" and http_get_fn then
    local candidates = {
      q:gsub("%s+", "_"),
      (q:gsub("%s+", "_") .. "_(algorithm)"),
      (q:gsub("%s+", "_") .. "_(data_structure)"),
    }
    for _, slug in ipairs(candidates) do
      local wiki_url = "https://en.wikipedia.org/api/rest_v1/page/summary/" .. slug
      local body = http_get_fn(wiki_url, { "Accept: application/json" }, 2)
      if body and body ~= "" then
        local ok, dec = pcall(vim.json.decode, body)
        if ok and type(dec) == "table" and dec.title and dec.extract and not dec.extract:match("^404:") then
          local desc = tostring(dec.description or "Algorithm / Data Structure")
          local title = tostring(dec.title)
          local vlines = {
            "# " .. title,
            "",
            "- **Category**: Wikipedia Computer Science (" .. desc .. ")",
            "- **Wikipedia URL**: " .. tostring(dec.content_urls and dec.content_urls.desktop and dec.content_urls.desktop.page or ("https://en.wikipedia.org/wiki/" .. slug)),
            "",
            "## Summary",
            "",
            dec.extract,
          }
          local first_sentence = dec.extract:match("^([^%.]+%.)") or dec.extract:sub(1, 100)
          local ctx = {
            string.format("%s  [%s]", title, desc),
            "Wikipedia Computer Science Reference",
            "Summary: " .. first_sentence,
            "Press <CR> to open full reference buffer",
          }
          table.insert(scored, {
            path = "wiki://" .. slug,
            line = 1,
            virtual_cursor_line = 1,
            col = 1,
            action = "navigate",
            match_type = "algo",
            provider = "algo",
            description = string.format("[Wikipedia] %s — %s", title, desc),
            score = 620,
            is_virtual = true,
            filetype = "markdown",
            context_lines = ctx,
            context_target_idx = 1,
            virtual_lines = vlines,
          })
          break
        end
      end
    end
  end

  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.path < b.path
  end)

  return scored
end

return M
