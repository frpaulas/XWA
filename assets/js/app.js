// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/xwa"
import {CodeEditorHook} from "../../deps/live_monaco_editor/priv/static/live_monaco_editor.esm"
import topbar from "../vendor/topbar"
import Graph from "graphology"
import Sigma from "sigma"
import forceAtlas2 from "graphology-layout-forceatlas2"
import { createNodePiechartProgram } from "@sigma/node-piechart"

// Synthesis node renderer: two equal slices, one per constituent graph.
// Colors chosen to contrast with the green regular-node palette.
const NodePiechartProgram = createNodePiechartProgram({
  defaultColor: "#9ca3af",
  slices: [
    { color: { value: "#3b82f6" }, value: { attribute: "slice_a" } },
    { color: { value: "#f59e0b" }, value: { attribute: "slice_b" } },
  ],
})

// Isolated node renderer: two-tone red piechart so visually-disconnected nodes
// are distinct from both regular nodes (green circles) and synthesis nodes (blue/amber).
// slice_a=1, slice_b=0 → full dark-red disc with piechart border.
const IsolatedNodeProgram = createNodePiechartProgram({
  defaultColor: "#fca5a5",
  slices: [
    { color: { value: "#dc2626" }, value: { attribute: "slice_a" } },
    { color: { value: "#fca5a5" }, value: { attribute: "slice_b" } },
  ],
})

// ---------------------------------------------------------------------------
// Sigma graph hook
// ---------------------------------------------------------------------------
const SigmaGraph = {
  mounted() {
    this._layoutDone = false
    this._pendingNeighborhood = null
    this._pendingFocus = null
    this._exploredNodes = []  // ordered array of center IDs, oldest first
    this._minDegree = 1
    this._inOverlay = false
    this._applyingOverlay = false
    // Visual state — read by nodeReducer/edgeReducer on every frame.
    // Mutate these objects and call sigma.refresh() to update the display.
    this._hiddenNodes = new Set()      // degree-filtered nodes
    this._hiddenEdges = new Set()      // degree-filtered edges
    this._overlayHidden = new Set()    // nodes hidden during neighborhood/focus overlay
    this._overlayHiddenEdges = new Set()
    this._dimmedNodes = new Set()      // focus-dimmed nodes
    this._dimmedEdges = new Set()      // focus-dimmed edges
    this._highlightedNode = null       // hover target
    this._hoveredNeighbors = new Set() // neighbors of hover target
    this._hoveredEdges = new Set()     // edges of hover target
    this._selectedNode = null
    this._trailNodes = new Set()       // previous exploration centers (purple)
    this._maxDegree = 1
    this._draggedNode = null           // node currently being dragged
    this._isDragging = false           // true once drag threshold exceeded
    this._didDrag = false              // latches true after threshold; consumed by clickNode
    this._dragStartPos = null          // {x, y} viewport coords at mousedown

    // Mount Sigma on a stable child div so LiveView re-renders don't destroy the canvas.
    this._container = document.createElement("div")
    this._container.style.cssText = "position:absolute;top:0;right:0;bottom:0;left:0;overflow:hidden;"
    this.el.appendChild(this._container)

    this.handleEvent("graph_loaded", (data) => {
      this._destroySigma()
      this._layoutDone = false
      this._pendingNeighborhood = null
      this._pendingFocus = null
      this._exploredNodes = []
      this._minDegree = data.min_degree || 1
      this._inOverlay = false
      this._applyingOverlay = false
      if (data.full_reload) this._showOverlay()
      this._initSigma(data)
    })

    this.handleEvent("neighborhood_changed", (neighborhood) => {
      this._pendingNeighborhood = neighborhood && neighborhood.center_id ? neighborhood : null
      this._pendingFocus = null
      if (this._layoutDone) this._applyPendingOverlay()
    })

    this.handleEvent("focus_changed", ({neighborhoods}) => {
      const hasFocus = neighborhoods && neighborhoods.length > 0
      this._pendingFocus = hasFocus ? neighborhoods : null
      if (hasFocus) {
        this._pendingNeighborhood = null
        if (this._layoutDone) this._applyPendingOverlay()
      }
    })

    const initialData = JSON.parse(this.el.dataset.graph)
    if (initialData.nodes && initialData.nodes.length > 0) {
      this._initSigma(initialData)
    }
  },

  updated() {},

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this._onDocMouseUp) document.removeEventListener("mouseup", this._onDocMouseUp)
    this._destroySigma()
  },

  _destroySigma() {
    if (this.sigma) { this.sigma.kill(); this.sigma = null }
    if (this.graph)  { this.graph.clear(); this.graph = null }
    this._hiddenNodes = new Set()
    this._hiddenEdges = new Set()
    this._overlayHidden = new Set()
    this._overlayHiddenEdges = new Set()
    this._dimmedNodes = new Set()
    this._dimmedEdges = new Set()
    this._highlightedNode = null
    this._hoveredNeighbors = new Set()
    this._hoveredEdges = new Set()
    this._selectedNode = null
    this._trailNodes = new Set()
    this._maxDegree = 1
    this._draggedNode = null
    this._isDragging = false
    this._didDrag = false
    this._dragStartPos = null
  },

  _showOverlay() {
    const overlay = document.getElementById("cy-loading")
    if (overlay) overlay.classList.remove("opacity-0", "pointer-events-none")
  },

  _hideOverlay() {
    const overlay = document.getElementById("cy-loading")
    if (overlay) overlay.classList.add("opacity-0", "pointer-events-none")
  },

  _applyPendingOverlay() {
    if (!this.sigma) return
    if (this._applyingOverlay) return
    this._applyingOverlay = true
    try {
      if (this._pendingFocus) {
        this._inOverlay = true
        this._selectedNode = null
        this._applyFocusMode(this._pendingFocus)
      } else if (this._pendingNeighborhood) {
        const n = this._pendingNeighborhood
        const hoodSet = new Set(n.ids || [])
        hoodSet.add(n.center_id)
        this._selectedNode = n.center_id
        const existingIdx = this._exploredNodes.indexOf(n.center_id)
        if (existingIdx !== -1) {
          this._exploredNodes = this._exploredNodes.slice(0, existingIdx + 1)
        } else {
          this._exploredNodes.push(n.center_id)
        }
        this._pendingNeighborhood = null
        this._inOverlay = true
        this._applyNeighborhood(hoodSet, n.center_id)
      } else if (this._inOverlay) {
        this._inOverlay = false
        this._exploredNodes = []
        this._selectedNode = null
        this._trailNodes = new Set()
        this._overlayHidden = new Set()
        this._overlayHiddenEdges = new Set()
        this._dimmedNodes = new Set()
        this._dimmedEdges = new Set()
        this._renderExploredLabels()
        this._applyDegreeFilter()
        this.sigma.refresh()
        this._updateStats()
        this._fitView()
      }
    } finally {
      this._applyingOverlay = false
    }
  },

  _applyNeighborhood(hoodSet, centerId) {
    // Everything outside the hood is hidden; trail nodes are always shown.
    this._overlayHidden = new Set()
    this._overlayHiddenEdges = new Set()
    this._dimmedNodes = new Set()
    this._dimmedEdges = new Set()
    this._trailNodes = new Set()

    this.graph.forEachNode((id) => {
      if (!hoodSet.has(id) && !this._exploredNodes.includes(id)) {
        this._overlayHidden.add(id)
      }
    })
    this.graph.forEachEdge((id, _attrs, source, target) => {
      const sourceVisible = hoodSet.has(source) || this._exploredNodes.includes(source)
      const targetVisible = hoodSet.has(target) || this._exploredNodes.includes(target)
      if (!sourceVisible || !targetVisible) {
        this._overlayHiddenEdges.add(id)
      }
    })

    // Mark trail nodes (previous centers) — purple in the reducer
    this._exploredNodes.forEach(id => {
      if (id !== centerId) this._trailNodes.add(id)
    })

    // Lay out the neighborhood concentrically around the center node
    this._concentricLayout(hoodSet, centerId)

    this._renderExploredLabels()
    this.sigma.refresh()
    this._updateStats()
    setTimeout(() => this._fitToNodes(hoodSet), 50)
  },

  _applyFocusMode(neighborhoods) {
    const centerIds = new Set(neighborhoods.map(h => h.center_id))
    const allHoodIds = new Set()
    neighborhoods.forEach(h => {
      allHoodIds.add(h.center_id)
      h.ids.forEach(id => allHoodIds.add(id))
    })

    this._overlayHidden = new Set()
    this._overlayHiddenEdges = new Set()
    this._dimmedNodes = new Set()
    this._dimmedEdges = new Set()
    this._trailNodes = centerIds

    this.graph.forEachNode((id) => {
      if (!allHoodIds.has(id)) this._dimmedNodes.add(id)
    })
    this.graph.forEachEdge((id, _attrs, source, target) => {
      if (!allHoodIds.has(source) || !allHoodIds.has(target)) this._dimmedEdges.add(id)
    })

    this.sigma.refresh()
    this._updateStats()
    setTimeout(() => this._fitToNodes(allHoodIds), 50)
  },

  _applyDegreeFilter() {
    this._hiddenNodes = new Set()
    this._hiddenEdges = new Set()
    if (this._minDegree > 1) {
      const min = this._minDegree
      this.graph.forEachNode((id) => {
        if (this.graph.degree(id) < min) this._hiddenNodes.add(id)
      })
      this.graph.forEachEdge((id, _attrs, source, target) => {
        if (this._hiddenNodes.has(source) || this._hiddenNodes.has(target)) {
          this._hiddenEdges.add(id)
        }
      })
    }
    // Color nodes and set type based on visible connectivity.
    // Visually-isolated nodes (no visible edges) get the "isolated" piechart renderer;
    // synthesis nodes restore their "piechart" type; regular nodes are left as default.
    this.graph.forEachNode((id) => {
      if (this._hiddenNodes.has(id)) return
      const hasVisibleEdge = this.graph.someEdge(id, (eid) => !this._hiddenEdges.has(eid))
      const isSynthesis = this.graph.getNodeAttribute(id, "node_type") === "synthesis"
      if (hasVisibleEdge) {
        this.graph.setNodeAttribute(id, "_color", sigmaNodeColor(this.graph.degree(id), this._maxDegree))
        this.graph.setNodeAttribute(id, "type", isSynthesis ? "piechart" : undefined)
        this.graph.setNodeAttribute(id, "slice_a", isSynthesis ? 1 : 0)
        this.graph.setNodeAttribute(id, "slice_b", isSynthesis ? 1 : 0)
      } else {
        this.graph.setNodeAttribute(id, "_color", "#f87171")
        this.graph.setNodeAttribute(id, "type", "isolated")
        this.graph.setNodeAttribute(id, "slice_a", 1)
        this.graph.setNodeAttribute(id, "slice_b", 1)  // equal halves → visible bicolor disc
      }
    })
  },

  // Place neighborhood nodes in concentric rings around centerId.
  // Center node is ring 0; its direct neighbors are ring 1.
  _concentricLayout(hoodSet, centerId) {
    const nodeIds = [...hoodSet].filter(id => this.graph.hasNode(id))
    if (!nodeIds.length) return

    const cx = this.graph.getNodeAttribute(centerId, "x") || 0
    const cy = this.graph.getNodeAttribute(centerId, "y") || 0

    // Separate center from ring nodes
    const ringNodes = nodeIds.filter(id => id !== centerId)
    const ringRadius = Math.max(150, ringNodes.length * 25)
    const angleStep = ringNodes.length > 0 ? (2 * Math.PI) / ringNodes.length : 0

    this.graph.setNodeAttribute(centerId, "x", cx)
    this.graph.setNodeAttribute(centerId, "y", cy)

    ringNodes.forEach((id, i) => {
      const angle = i * angleStep - Math.PI / 2
      this.graph.setNodeAttribute(id, "x", cx + ringRadius * Math.cos(angle))
      this.graph.setNodeAttribute(id, "y", cy + ringRadius * Math.sin(angle))
    })
  },

  // Fit the Sigma camera to show a subset of nodes.
  // Sigma normalizes all graph coords to [0,1] internally. The camera default
  // state {x:0.5, y:0.5, ratio:1} shows the full graph. For subsets we
  // compute bounds in normalized display space and set camera accordingly.
  _fitToNodes(nodeIdSet) {
    if (!this.sigma || !nodeIdSet.size) return
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    nodeIdSet.forEach(id => {
      if (!this.graph.hasNode(id)) return
      const display = this.sigma.getNodeDisplayData(id)
      if (!display) return
      if (display.x < minX) minX = display.x
      if (display.x > maxX) maxX = display.x
      if (display.y < minY) minY = display.y
      if (display.y > maxY) maxY = display.y
    })
    if (!isFinite(minX)) {
      // No display data yet — fall back to showing full graph
      this.sigma.getCamera().setState({x: 0.5, y: 0.5, ratio: 1, angle: 0})
      return
    }
    const cx = (minX + maxX) / 2
    const cy = (minY + maxY) / 2
    const spanX = maxX - minX || 0.001
    const spanY = maxY - minY || 0.001
    // Camera ratio 1 shows a normalized span of 1.0. Scale proportionally,
    // adding 25% padding (multiply by 1.25).
    const ratio = Math.max(spanX, spanY) * 1.25
    this.sigma.getCamera().setState({x: cx, y: cy, ratio, angle: 0})
  },

  _fitView() {
    if (!this.sigma || !this.graph) return
    const visibleIds = []
    this.graph.forEachNode((id) => {
      if (!this._hiddenNodes.has(id) && !this._overlayHidden.has(id)) visibleIds.push(id)
    })
    if (visibleIds.length === 0) {
      this.sigma.getCamera().setState({x: 0.5, y: 0.5, ratio: 1, angle: 0})
      return
    }
    this._fitToNodes(new Set(visibleIds))
  },

  _renderExploredLabels() {
    const container = document.getElementById("cy-explored-labels")
    if (!container) return
    container.innerHTML = ""
    this._exploredNodes.forEach((id, idx) => {
      const label = this.graph ? (this.graph.getNodeAttribute(id, "label") || id) : id
      const isCurrent = idx === this._exploredNodes.length - 1
      const el = document.createElement("button")
      el.title = isCurrent ? "Current node" : `Back to: ${label}`
      el.style.cssText = "display:flex;align-items:center;gap:4px;text-align:left;max-width:220px;min-width:0;"
      el.className = [
        "text-xs font-medium px-2 py-1 rounded transition-colors",
        isCurrent
          ? "bg-primary/80 text-primary-content cursor-default"
          : "bg-violet-500/80 text-white hover:bg-violet-400 cursor-pointer",
      ].join(" ")
      if (!isCurrent) {
        const arrow = document.createElement("span")
        arrow.textContent = "←"
        arrow.style.flexShrink = "0"
        el.appendChild(arrow)
      }
      const text = document.createElement("span")
      text.textContent = label
      text.style.cssText = "overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
      el.appendChild(text)
      if (!isCurrent) {
        el.addEventListener("click", () => this.pushEvent("unwind_to", {id}))
      }
      container.appendChild(el)
    })
  },

  _initSigma(data) {
    const colors = resolveColors()
    this.graph = new Graph({multi: true, type: "directed"})

    // Add nodes
    data.nodes.forEach(({data: d}) => {
      const isSynthesis = d.node_type === "synthesis"
      this.graph.addNode(d.id, {
        label: d.label || d.id,
        // Store semantic type separately — Sigma uses `type` to pick the renderer,
        // so we only set it for nodes that need a custom program.
        semanticType: d.type,
        node_type: d.node_type || "claim",
        type: isSynthesis ? "piechart" : undefined,
        slice_a: isSynthesis ? 1 : 0,
        slice_b: isSynthesis ? 1 : 0,
        corpus_layer: d.corpus_layer,
        confidence: d.confidence ?? 1.0,
        human_validated: d.human_validated ?? false,
        contested: d.contested ?? false,
        x: Math.random() * 1000,
        y: Math.random() * 1000,
        size: 8,
        color: "#6b7280",
      })
    })

    // Add edges
    data.edges.forEach(({data: d}) => {
      if (this.graph.hasNode(d.source) && this.graph.hasNode(d.target)) {
        this.graph.addEdgeWithKey(d.id, d.source, d.target, {
          type: d.type || "relates",
          certainty: d.certainty || "dashed",
          confidence: d.confidence ?? 0.5,
          cross_graph: d.cross_graph ?? false,
        })
      }
    })

    // Compute degree-based node attributes once (used by reducers)
    this._maxDegree = 1
    this.graph.forEachNode((id) => {
      const deg = this.graph.degree(id)
      if (deg > this._maxDegree) this._maxDegree = deg
    })
    this.graph.forEachNode((id) => {
      const deg = this.graph.degree(id)
      const isSynthesis = this.graph.getNodeAttribute(id, "node_type") === "synthesis"
      // Synthesis nodes are larger so the pie slices are clearly legible
      this.graph.setNodeAttribute(id, "_size", isSynthesis ? sigmaNodeSize(deg) + 8 : sigmaNodeSize(deg))
      this.graph.setNodeAttribute(id, "_color", sigmaNodeColor(deg, this._maxDegree))
    })

    const nodeCount = this.graph.order
    const msg = document.getElementById("cy-loading-msg")
    if (msg && nodeCount > 0) msg.textContent = `Laying out ${nodeCount} nodes…`

    this.sigma = new Sigma(this.graph, this._container, {
      minCameraRatio: 0.02,
      maxCameraRatio: 20,
      renderEdgeLabels: false,
      defaultEdgeType: "arrow",
      zIndex: true,   // respect zIndex returned by reducers
      nodeProgramClasses: { piechart: NodePiechartProgram, isolated: IsolatedNodeProgram },
      nodeReducer: (id, attrs) => this._nodeReducer(id, attrs, colors),
      edgeReducer: (id, attrs) => this._edgeReducer(id, attrs, colors),
    })

    // Events
    this.sigma.on("clickNode", ({node}) => {
      if (this._didDrag) { this._didDrag = false; return }  // consumed: drag just ended
      const currentCenter = this._exploredNodes[this._exploredNodes.length - 1]
      const prevIdx = this._exploredNodes.indexOf(node)
      if (prevIdx !== -1 && node !== currentCenter) {
        this.pushEvent("unwind_to", {id: node})
      } else {
        this.pushEvent("node_selected", {id: node})
      }
    })

    this.sigma.on("clickStage", () => {
      this.pushEvent("deselect", {})
    })

    this.sigma.on("enterNode", ({node}) => {
      this._highlightedNode = node
      this._hoveredNeighbors = new Set(this.graph.neighbors(node))
      this._hoveredEdges = new Set()
      this.graph.forEachEdge(node, (id) => this._hoveredEdges.add(id))
      const label = this.graph.getNodeAttribute(node, "label") || node
      const text = document.getElementById("cy-hover-text")
      if (text) { text.textContent = label; text.style.display = "block" }
      this.sigma.refresh()
    })

    this.sigma.on("leaveNode", () => {
      this._highlightedNode = null
      this._hoveredNeighbors = new Set()
      this._hoveredEdges = new Set()
      const text = document.getElementById("cy-hover-text")
      if (text) text.style.display = "none"
      this.sigma.refresh()
    })

    // Node drag — record mousedown on node, begin dragging once pointer moves
    // > 5px so normal clicks are not swallowed.
    // Sigma's event coords are at e.x / e.y (viewport pixels), NOT e.event.x.
    this.sigma.on("downNode", (e) => {
      this._draggedNode = e.node
      this._isDragging = false
      this._didDrag = false
      this._dragStartPos = {x: e.x, y: e.y}
      e.preventSigmaDefault()  // stop Sigma starting a camera pan on this mousedown
    })

    // Use getMouseCaptor() so preventSigmaDefault() actually blocks camera panning.
    this.sigma.getMouseCaptor().on("mousemovebody", (e) => {
      if (!this._draggedNode) return
      // Block sigma camera AND browser default while a node drag is in progress.
      e.preventSigmaDefault()
      e.original.preventDefault()
      e.original.stopPropagation()
      if (!this._isDragging) {
        const dx = e.x - this._dragStartPos.x
        const dy = e.y - this._dragStartPos.y
        if (Math.sqrt(dx * dx + dy * dy) < 5) return
        this._isDragging = true
        this._didDrag = true  // latch: survives mouseup cleanup, consumed by clickNode
      }
      const pos = this.sigma.viewportToGraph({x: e.x, y: e.y})
      this.graph.setNodeAttribute(this._draggedNode, "x", pos.x)
      this.graph.setNodeAttribute(this._draggedNode, "y", pos.y)
      this.sigma.refresh()
    })

    // Use document mouseup so drag cleans up even if mouse is released outside the container.
    this._onDocMouseUp = () => {
      this._draggedNode = null
      this._isDragging = false
      this._dragStartPos = null
    }
    document.addEventListener("mouseup", this._onDocMouseUp)

    this._resizeObserver = new ResizeObserver(() => this.sigma && this.sigma.refresh())
    this._resizeObserver.observe(this.el)

    // Run layout after the browser has painted
    setTimeout(() => {
      this._runLayout(nodeCount)
    }, 50)
  },

  _runLayout(nodeCount) {
    if (nodeCount === 0) {
      this._onLayoutDone()
      return
    }
    // ForceAtlas2 for all sizes — scale iterations down for large graphs.
    const iterations = nodeCount > 500 ? 30 : nodeCount > 150 ? 80 : 300
    forceAtlas2.assign(this.graph, {
      iterations,
      settings: forceAtlas2.inferSettings(this.graph),
    })
    this._onLayoutDone()
  },

  // Place visually-isolated nodes (type:"isolated", set by _applyDegreeFilter) on a
  // ring around the connected component.  Catches both graphology degree-0 nodes and
  // nodes whose edges are all hidden by the current degree filter.
  _placeIsolatedNodes() {
    const isolated = []
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity

    this.graph.forEachNode((id) => {
      if (this._hiddenNodes.has(id)) return
      if (this.graph.getNodeAttribute(id, "type") === "isolated") {
        isolated.push(id)
      } else {
        const x = this.graph.getNodeAttribute(id, "x")
        const y = this.graph.getNodeAttribute(id, "y")
        if (x < minX) minX = x
        if (x > maxX) maxX = x
        if (y < minY) minY = y
        if (y > maxY) maxY = y
      }
    })

    if (isolated.length === 0) return
    if (!isFinite(minX)) { minX = 0; maxX = 0; minY = 0; maxY = 0 }

    const cx = (minX + maxX) / 2
    const cy = (minY + maxY) / 2
    // Ring radius: just outside the bounding circle of the connected component.
    const halfDiag = Math.hypot(maxX - minX, maxY - minY) / 2
    const radius = Math.max(halfDiag * 1.7, 200)
    const angleStep = (2 * Math.PI) / isolated.length

    isolated.forEach((id, i) => {
      const angle = i * angleStep - Math.PI / 2   // start from top
      this.graph.setNodeAttribute(id, "x", cx + radius * Math.cos(angle))
      this.graph.setNodeAttribute(id, "y", cy + radius * Math.sin(angle))
    })
  },

  // BFS over visible nodes to find multi-node connected components, then
  // translate each smaller component to the right of the largest so they
  // don't visually merge as the degree filter is loosened.
  // Single-node isolated components are already handled by _placeIsolatedNodes.
  _separateComponents() {
    const visible = new Set()
    this.graph.forEachNode(id => {
      if (!this._hiddenNodes.has(id)) visible.add(id)
    })
    if (visible.size < 2) return

    // BFS — only traverse edges whose both endpoints are visible
    const visited = new Set()
    const components = []

    visible.forEach(startId => {
      if (visited.has(startId)) return
      const comp = []
      const queue = [startId]
      visited.add(startId)
      while (queue.length > 0) {
        const id = queue.shift()
        comp.push(id)
        this.graph.forEachNeighbor(id, nbr => {
          if (visible.has(nbr) && !visited.has(nbr)) {
            visited.add(nbr); queue.push(nbr)
          }
        })
      }
      if (comp.length > 1) components.push(comp)  // skip degree-0 singletons
    })

    if (components.length <= 1) return  // only one real component

    // Bounding box per component
    const boxes = components.map(nodeIds => {
      let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
      nodeIds.forEach(id => {
        const x = this.graph.getNodeAttribute(id, "x")
        const y = this.graph.getNodeAttribute(id, "y")
        minX = Math.min(minX, x); maxX = Math.max(maxX, x)
        minY = Math.min(minY, y); maxY = Math.max(maxY, y)
      })
      return { nodeIds, minX, maxX, minY, maxY, w: maxX - minX, h: maxY - minY }
    })

    // Largest component stays put; others line up to its right, vertically centered
    boxes.sort((a, b) => b.nodeIds.length - a.nodeIds.length)
    const main = boxes[0]
    const gap = Math.max(200, main.w * 0.3)
    let cursor = main.maxX + gap

    for (let i = 1; i < boxes.length; i++) {
      const box = boxes[i]
      const dx = cursor - box.minX
      const dy = (main.minY + main.h / 2) - (box.minY + box.h / 2)
      box.nodeIds.forEach(id => {
        this.graph.setNodeAttribute(id, "x", this.graph.getNodeAttribute(id, "x") + dx)
        this.graph.setNodeAttribute(id, "y", this.graph.getNodeAttribute(id, "y") + dy)
      })
      cursor += box.w + gap
    }
  },

  _onLayoutDone() {
    this._layoutDone = true
    this._applyDegreeFilter()
    this._placeIsolatedNodes()  // must run after _applyDegreeFilter sets type:"isolated"
    this._separateComponents()  // must run after _applyDegreeFilter sets _hiddenNodes
    this._hideOverlay()
    this.sigma.refresh()
    this._updateStats()
    // Defer fit: getNodeDisplayData is only populated after Sigma's first render pass.
    setTimeout(() => {
      this._fitView()
      this._applyPendingOverlay()
    }, 50)
  },

  // Update the bottom-right stat pill to show "m of n nodes · i of j edges"
  // when some nodes/edges are hidden, or plain counts when all are visible.
  _updateStats() {
    const el = document.getElementById("cy-graph-stats")
    if (!el || !this.graph) return
    const totalN = this.graph.order
    const totalE = this.graph.size
    const hiddenN = this._hiddenNodes.size + this._overlayHidden.size
    const hiddenE = this._hiddenEdges.size + this._overlayHiddenEdges.size
    const shownN = totalN - hiddenN
    const shownE = totalE - hiddenE
    el.textContent = (shownN === totalN && shownE === totalE)
      ? `${totalN} nodes · ${totalE} edges`
      : `${shownN} of ${totalN} nodes · ${shownE} of ${totalE} edges`
  },

  // nodeReducer: called by Sigma on every render pass for each node.
  // Returns the display attributes for that node based on current state.
  _nodeReducer(id, attrs, colors) {
    const result = {
      x: attrs.x,
      y: attrs.y,
      size: attrs._size || 8,
      color: attrs._color || colors.neutral,
      type: attrs.type,       // "piechart" (SN), "isolated", or undefined (regular)
      slice_a: attrs.slice_a,
      slice_b: attrs.slice_b,
      hidden: false,
      // Degree-based zIndex 0–10; trail=20, selected/hover=30 always on top.
      zIndex: Math.round((this.graph.degree(id) / Math.max(this._maxDegree, 1)) * 10),
    }

    // Degree filter
    if (this._hiddenNodes.has(id)) { result.hidden = true; return result }

    // Overlay visibility (neighborhood mode)
    if (this._overlayHidden.has(id)) { result.hidden = true; return result }

    // Focus dimming
    if (this._dimmedNodes.has(id)) {
      result.color = colors.neutral
      result.size = Math.max(result.size * 0.5, 3)
      return result
    }

    // Trail nodes (previous exploration centers) — violet
    if (this._trailNodes.has(id)) {
      result.color = "#8b5cf6"
      result.size = result.size + 3
      result.zIndex = 20
      return result
    }

    // Selected node — amber
    if (id === this._selectedNode) {
      result.color = "#f59e0b"
      result.size = result.size + 6
      result.zIndex = 30
      return result
    }

    // Hover: highlight hovered node and its neighbors
    if (this._highlightedNode) {
      if (id === this._highlightedNode) {
        result.size = result.size + 4
        result.zIndex = 30
      } else if (this._hoveredNeighbors.has(id)) {
        result.color = "#f59e0b"
        result.zIndex = 20
      }
    }

    // human_validated gets a lighter border (simulated via slightly larger size)
    if (attrs.human_validated) result.size = result.size + 1

    return result
  },

  // edgeReducer: called by Sigma on every render pass for each edge.
  _edgeReducer(id, attrs, colors) {
    const result = {
      color: colors.neutral,
      size: 0.5 + (attrs.confidence ?? 0.5) * 2,
      hidden: false,
      zIndex: 0,
    }

    if (attrs.cross_graph) result.color = "#f59e0b"

    // Degree filter
    if (this._hiddenEdges.has(id)) { result.hidden = true; return result }

    // Overlay visibility
    if (this._overlayHiddenEdges.has(id)) { result.hidden = true; return result }

    // Focus dimming
    if (this._dimmedEdges.has(id)) {
      result.color = colors.neutral
      result.size = 0.5
      return result
    }

    // Hover highlight
    if (this._hoveredEdges.has(id)) {
      const source = this.graph.source(id)
      const target = this.graph.target(id)
      const edgeType = this.graph.getEdgeAttribute(id, "type")
      result.color = edgeTypeColor(edgeType)
      result.size = 3
      result.zIndex = 1
    }

    return result
  },
}

// Assign one of 3 colors to an edge based on its type string.
const EDGE_COLORS = ["#38bdf8", "#a78bfa", "#fb7185"]
function edgeTypeColor(type) {
  if (!type) return EDGE_COLORS[0]
  let hash = 0
  for (let i = 0; i < type.length; i++) hash = (hash * 31 + type.charCodeAt(i)) | 0
  return EDGE_COLORS[Math.abs(hash) % EDGE_COLORS.length]
}

function sigmaNodeSize(deg) {
  // Minimum 5 so isolated (0-edge) nodes are visible; scale logarithmically from there.
  return 5 + Math.log1p(deg) * 2.5
}

// Sigma's parseColor only handles hex and rgb() — no hsl(), no oklch().
// Convert HSL to hex so WebGL receives a format it can parse.
function hslToHex(h, s, l) {
  s /= 100; l /= 100
  const a = s * Math.min(l, 1 - l)
  const f = n => {
    const k = (n + h / 30) % 12
    const c = l - a * Math.max(Math.min(k - 3, 9 - k, 1), -1)
    return Math.round(255 * c).toString(16).padStart(2, "0")
  }
  return `#${f(0)}${f(8)}${f(4)}`
}

function sigmaNodeColor(deg, maxDeg) {
  if (deg === 0) return "#f87171"  // red-400: isolated nodes stand out
  const t = Math.log1p(deg) / Math.log1p(Math.max(maxDeg, 1))
  // Tailwind green range: 142° hue. Bright mint → rich forest green.
  const lightness = Math.round(65 - t * 23)
  return hslToHex(142, 76, lightness)
}

// Force any CSS color string (including oklch, hsl) to a hex value by
// painting a 1×1 canvas — the browser does the conversion for us.
function cssColorToHex(cssValue) {
  try {
    const canvas = document.createElement("canvas")
    canvas.width = canvas.height = 1
    const ctx = canvas.getContext("2d")
    ctx.fillStyle = cssValue
    ctx.fillRect(0, 0, 1, 1)
    const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data
    return `#${r.toString(16).padStart(2,"0")}${g.toString(16).padStart(2,"0")}${b.toString(16).padStart(2,"0")}`
  } catch { return null }
}

// Read computed color values from CSS variables (daisyUI theme) and convert
// them to hex so Sigma's WebGL renderer can parse them.
// DaisyUI v5 uses raw oklch channel values; we wrap and resolve via canvas.
function resolveColors() {
  const cs = getComputedStyle(document.documentElement)
  const get = (v, fallback) => {
    const raw = cs.getPropertyValue(v).trim()
    if (!raw) return fallback
    const css = raw.startsWith("oklch") || raw.startsWith("hsl") || raw.startsWith("rgb") || raw.startsWith("#")
      ? raw
      : `oklch(${raw})`
    return cssColorToHex(css) || fallback
  }
  return {
    neutral: get("--n",  "#6b7280"),
    primary: get("--p",  "#6366f1"),
  }
}

// ---------------------------------------------------------------------------
// CopyToClipboard hook
// ---------------------------------------------------------------------------
const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.clipboard
      if (!text) return
      navigator.clipboard.writeText(text).then(() => {
        this.el.style.opacity = "0.4"
        setTimeout(() => { this.el.style.opacity = "" }, 600)
      })
    })
  }
}

// ---------------------------------------------------------------------------
// MonacoFix hook
// ---------------------------------------------------------------------------
// live_monaco_editor's CodeEditorHook registers onDidContentSizeChange which
// sets this.el.style.height = contentHeight + "px", making the editor grow to
// fit all content instead of scrolling. We counteract this by watching for
// that style mutation and immediately resetting the height back to "100%" so
// that Monaco fills its fixed-height wrapper and scrolls internally.
const MonacoFix = {
  mounted() {
    const findEditor = () => this.el.querySelector('[id^="lme-code-"]')
    const fix = (el) => { if (el && el.style.height !== "100%") el.style.height = "100%" }

    const observer = new MutationObserver(() => fix(findEditor()))
    observer.observe(this.el, { subtree: true, attributes: true, attributeFilter: ["style"] })
    this._monacoObserver = observer

    // Fix once after a short delay to catch the initial render
    setTimeout(() => fix(findEditor()), 100)
  },
  destroyed() {
    if (this._monacoObserver) this._monacoObserver.disconnect()
  }
}

// ---------------------------------------------------------------------------
// DegreeSlider hook — updates label live while dragging, pushes server event
// only on mouseup so the graph doesn't rebuild on every tick.
// ---------------------------------------------------------------------------
const DegreeSlider = {
  mounted() {
    const label = document.getElementById("cy-degree-label")
    const input = this.el

    input.addEventListener("input", () => {
      if (label) label.textContent = input.value
    })

    input.addEventListener("change", () => {
      this.pushEvent("filter_min_degree", {min_degree: input.value})
    })
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, SigmaGraph, CodeEditorHook, MonacoFix, CopyToClipboard, DegreeSlider},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Mobile menu toggle
document.addEventListener("DOMContentLoaded", () => {
  const btn = document.getElementById("mobile-menu-btn")
  const menu = document.getElementById("mobile-menu")
  if (btn && menu) {
    btn.addEventListener("click", () => {
      const open = !menu.classList.contains("hidden")
      menu.classList.toggle("hidden", open)
      menu.setAttribute("aria-hidden", String(open))
      btn.setAttribute("aria-expanded", String(!open))
    })
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

