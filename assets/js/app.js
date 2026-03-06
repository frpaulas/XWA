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
import { NodeCircleProgram } from "sigma/rendering"
import { scalePoint, scaleSequential, scaleLinear } from "d3-scale"
import { interpolateRdYlBu } from "d3-scale-chromatic"
import { path as d3path } from "d3-path"

// Synthesis node renderer: two equal slices, one per constituent graph.
// Colors chosen to contrast with the blue regular-node palette.
const NodePiechartProgram = createNodePiechartProgram({
  defaultColor: "#9ca3af",
  slices: [
    { color: { value: "#3b82f6" }, value: { attribute: "slice_a" } },
    { color: { value: "#f59e0b" }, value: { attribute: "slice_b" } },
  ],
})

// Phong-shaded sphere program: extends NodeCircleProgram (inherits all attribute/
// picking machinery) and replaces only the fragment shader with a per-pixel
// Phong lighting model. Gives a mathematically correct 3D sphere at any zoom level.
//
// Light from upper-left (-x, +y in uv-space, angled toward the viewer).
// Diffuse + specular (shininess=48) + ambient(0.2) → white specular highlight.
const _PHONG_FRAG = `
precision highp float;

varying vec4 v_color;
varying vec2 v_diffVector;
varying float v_radius;

uniform float u_correctionRatio;

const vec4 transparent = vec4(0.0, 0.0, 0.0, 0.0);

void main(void) {
  float border  = u_correctionRatio * 2.0;
  float rawDist = length(v_diffVector);
  float dist    = rawDist - v_radius + border;  // <0 inside, >border outside

  #ifdef PICKING_MODE
    gl_FragColor = dist > border ? transparent : v_color;
  #else
    if (dist > border) { gl_FragColor = transparent; return; }

    // Normalised position inside the disc: centre=(0,0), rim=1
    vec2  uv = v_diffVector / max(v_radius, 0.001);
    float r2 = dot(uv, uv);

    // Clamp r2 to 1 so sqrt is safe in the anti-alias fringe
    vec3  normal   = normalize(vec3(uv, sqrt(max(0.0, 1.0 - r2))));
    vec3  lightDir = normalize(vec3(-0.55, 0.75, 0.50));
    vec3  halfVec  = normalize(lightDir + vec3(0.0, 0.0, 1.0));

    float diffuse  = max(dot(normal, lightDir), 0.0);
    float spec     = pow(max(dot(normal, halfVec), 0.0), 48.0);

    vec3  shaded = v_color.rgb * (0.20 + diffuse * 0.80) + vec3(spec * 0.65);
    float alpha  = v_color.a * (1.0 - max(0.0, dist) / max(border, 0.001));

    gl_FragColor = vec4(clamp(shaded, 0.0, 1.0), clamp(alpha, 0.0, 1.0));
  #endif
}
`

class NodeSphereProgram extends NodeCircleProgram {
  getDefinition() {
    return { ...super.getDefinition(), FRAGMENT_SHADER_SOURCE: _PHONG_FRAG }
  }
}

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
    this._currentLayer = "all"         // last applied layer filter (for saving views)
    this._currentType  = "all"         // last applied type filter
    this._hideIsolated = true          // hide dimension-0 nodes (degree === 0) by default
    this._pendingViewId = null         // save ID being loaded — positions applied in graph_loaded handler
    this._skipLayout = false           // set when saved-view positions are pre-loaded; skips FA2/auto-save
    this._pendingOverlayRestore = null // overlay state to restore after layout (from a saved view)
    this._mouseX = 0                   // cursor position relative to this.el, updated on mousemove
    this._mouseY = 0
    this._selectedEdge = null          // currently clicked edge
    this._edgeHighlightedNodes = new Set() // endpoints of _selectedEdge
    this._lastCenterId = null          // saved for re-render on AD expand
    this._lastHoodSet = null           // saved for re-render on AD expand

    // Track cursor position for tooltip anchoring.
    this._onMouseMove = (e) => {
      const rect = this.el.getBoundingClientRect()
      this._mouseX = e.clientX - rect.left
      this._mouseY = e.clientY - rect.top
      // Keep tooltip pinned near cursor while hovering a node.
      if (this._highlightedNode) {
        const tip = document.getElementById("node-tooltip")
        if (tip && tip.style.display !== "none") this._positionTooltip(tip)
      }
    }
    this.el.addEventListener("mousemove", this._onMouseMove)

    // Event delegation for expand button — works even when button is conditionally rendered by LiveView
    this._onDocClick = (e) => {
      if (e.target.closest("#arc-expand-btn")) this._openArcModal()
    }
    document.addEventListener("click", this._onDocClick)

    // Modal close listeners (modal is always in DOM, so direct binding is fine)
    const closeBtn = document.getElementById("arc-modal-close")
    if (closeBtn) closeBtn.addEventListener("click", () => this._closeArcModal())
    const modal = document.getElementById("arc-modal")
    if (modal) modal.addEventListener("click", (e) => {
      if (e.target === modal) this._closeArcModal()
    })

    this._onKeyDown = (e) => {
      if (e.key === "Escape") this._closeArcModal()
    }
    document.addEventListener("keydown", this._onKeyDown)

    // Mount Sigma on a stable child div so LiveView re-renders don't destroy the canvas.
    this._container = document.createElement("div")
    this._container.style.cssText = "position:absolute;top:0;right:0;bottom:0;left:0;overflow:hidden;"
    this.el.appendChild(this._container)

    this.handleEvent("graph_loaded", (data) => {
      this._destroySigma()
      this._layoutDone = false
      this._skipLayout = false
      this._pendingOverlayRestore = null
      this._pendingNeighborhood = null
      this._pendingFocus = null
      this._exploredNodes = []
      this._selectedEdge = null
      this._edgeHighlightedNodes = new Set()
      this._minDegree = data.min_degree || 1
      this._currentLayer = data.layer  || "all"
      this._currentType  = data.type   || "all"
      this._inOverlay = false
      this._applyingOverlay = false
      if (data.graph_id) this._graphId = data.graph_id
      if (data.full_reload) this._showOverlay()
      this._initSigma(data)
      // Apply named-view positions directly into the freshly-built graph, before
      // _runLayout fires. Set _skipLayout so _runLayout uses these positions without
      // going through the auto-save round-trip (which could fail or use stale data).
      if (this._pendingViewId) {
        const save = this._listSaves().find(s => s.id === this._pendingViewId)
        this._pendingViewId = null
        if (save && save.positions && this.graph) {
          this.graph.forEachNode((id) => {
            if (save.positions[id]) {
              this.graph.setNodeAttribute(id, "x", save.positions[id].x)
              this.graph.setNodeAttribute(id, "y", save.positions[id].y)
            }
          })
          this._skipLayout = true   // positions are already in the graph; skip FA2/auto-save
          this._persistAutoSave()   // persist for subsequent filter-change reloads
          // Restore neighborhood overlay if the view was saved in overlay mode
          if (save.overlayState) this._pendingOverlayRestore = save.overlayState
        }
      }
      this._renderSavedViewsPanel()
    })

    // Layout persistence — triggered by buttons via CustomEvent dispatch on this.el
    this.el.addEventListener("show-save-view-dialog", () => this._showSaveViewDialog())
    this.el.addEventListener("reset-layout", () => this._resetLayout())

    // Saved-views list interactions — event delegation on the list container.
    // Rendered items set data-load-view or data-delete-view attributes.
    const savesList = document.getElementById("cy-saves-list")
    if (savesList) {
      savesList.addEventListener("click", (e) => {
        const loadBtn   = e.target.closest("[data-load-view]")
        const deleteBtn = e.target.closest("[data-delete-view]")
        if (loadBtn)   this._loadView(loadBtn.dataset.loadView)
        if (deleteBtn) this._deleteView(deleteBtn.dataset.deleteView)
      })
    }

    // Save-view dialog confirm / cancel
    const confirmBtn = document.getElementById("cy-save-view-confirm")
    const cancelBtn  = document.getElementById("cy-save-view-cancel")
    const nameInput  = document.getElementById("cy-save-view-name")
    if (confirmBtn) confirmBtn.addEventListener("click", () => {
      const name = nameInput.value.trim() || this._smartSaveName()
      this._saveView(name)
      this._hideSaveViewDialog()
    })
    if (cancelBtn) cancelBtn.addEventListener("click", () => this._hideSaveViewDialog())
    if (nameInput) nameInput.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { confirmBtn && confirmBtn.click() }
      if (e.key === "Escape") this._hideSaveViewDialog()
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

    this.handleEvent("toggle_isolated", ({hide}) => {
      this._hideIsolated = hide
      this._applyDegreeFilter()
      this.sigma && this.sigma.refresh()
      this._updateStats && this._updateStats()
    })

    // Capture graph_id from the DOM attribute (set at mount time, stable across reloads).
    this._graphId = this.el.dataset.graphId || null

    // Populate saved views panel immediately (reads from localStorage).
    this._renderSavedViewsPanel()

    const initialData = JSON.parse(this.el.dataset.graph)
    if (initialData.nodes && initialData.nodes.length > 0) {
      this._initSigma(initialData)
    }
  },

  // Called after every LiveView re-render. Re-populate the saves panel because
  // #cy-saves-list is in normal LiveView-managed DOM and gets reset by patches.
  updated() {
    this._renderSavedViewsPanel()
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this._onDocMouseUp)  document.removeEventListener("mouseup",    this._onDocMouseUp)
    if (this._onMouseMove)   this.el.removeEventListener("mousemove",   this._onMouseMove)
    if (this._onBoxKeyDown)  document.removeEventListener("keydown",    this._onBoxKeyDown)
    if (this._onBoxKeyUp)    document.removeEventListener("keyup",      this._onBoxKeyUp)
    if (this._onBoxMove)     document.removeEventListener("mousemove",  this._onBoxMove)
    if (this._onBoxUp)       document.removeEventListener("mouseup",    this._onBoxUp)
    if (this._onKeyDown)     document.removeEventListener("keydown",    this._onKeyDown)
    if (this._onDocClick)    document.removeEventListener("click",     this._onDocClick)
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
        this._clearArcDiagram()
      }
    } finally {
      this._applyingOverlay = false
    }
  },

  _applyNeighborhood(hoodSet, centerId) {
    this._lastHoodSet = hoodSet
    this._lastCenterId = centerId
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
    this._renderArcDiagram(centerId, hoodSet)
    setTimeout(() => this._fitToNodes(hoodSet), 50)
  },

  // Vertical arc diagram rendered into #arc-diagram in the sidebar.
  // Nodes sorted by confidence descending (high confidence = top = blue).
  // Arcs bow to the left; center node has a ring border.
  _renderArcDiagram(centerId, hoodSet) {
    const el = document.getElementById("arc-diagram")
    if (!el || !this.graph) return
    const expandBtn = document.getElementById("arc-expand-btn")
    if (expandBtn) expandBtn.classList.replace("hidden", "flex")

    const allIds = Array.from(hoodSet)
    const nodes = allIds.map(id => ({
      id,
      label: this.graph.getNodeAttribute(id, "label") || id,
      confidence: this.graph.getNodeAttribute(id, "confidence") ?? 1.0,
      color: confidenceColor(this.graph.getNodeAttribute(id, "confidence") ?? 1.0),
      isCenter: id === centerId,
    })).sort((a, b) => b.confidence - a.confidence || (a.isCenter ? -1 : 1))

    const edges = []
    this.graph.forEachEdge((eid, attrs, source, target) => {
      if (hoodSet.has(source) && hoodSet.has(target)) {
        edges.push({ source, target, certainty: attrs.certainty || "solid" })
      }
    })

    const W = el.clientWidth || 272
    const expanded = W > 400
    const nodeSpacing = expanded ? 40 : 28
    const topPad = expanded ? 20 : 14
    const spineX = expanded ? Math.round(W * 0.18) : 68
    const maxLabel = expanded ? 80 : 30
    const fontSize = expanded ? 12 : 10
    const H = topPad * 2 + nodeSpacing * Math.max(nodes.length - 1, 0)
    const ns = "http://www.w3.org/2000/svg"

    const yPos = {}
    nodes.forEach((n, i) => { yPos[n.id] = topPad + i * nodeSpacing })

    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("width", W)
    svg.setAttribute("height", H)
    svg.style.display = "block"

    // Spine
    const spine = document.createElementNS(ns, "line")
    spine.setAttribute("x1", spineX); spine.setAttribute("y1", topPad)
    spine.setAttribute("x2", spineX); spine.setAttribute("y2", H - topPad)
    spine.setAttribute("stroke", "#d1d5db"); spine.setAttribute("stroke-width", "1")
    svg.appendChild(spine)

    // Arcs (bow left)
    edges.forEach(e => {
      const y1 = yPos[e.source], y2 = yPos[e.target]
      if (y1 === undefined || y2 === undefined) return
      const bow = Math.max(Math.abs(y2 - y1) * 0.45, 8)
      const dashArr = e.certainty === "dashed" ? "4 2" : e.certainty === "dotted" ? "1 3" : "none"
      const path = document.createElementNS(ns, "path")
      path.setAttribute("d", `M ${spineX} ${y1} C ${spineX - bow} ${y1} ${spineX - bow} ${y2} ${spineX} ${y2}`)
      path.setAttribute("fill", "none")
      path.setAttribute("stroke", "#94a3b8")
      path.setAttribute("stroke-width", "1.5")
      path.setAttribute("stroke-dasharray", dashArr)
      path.setAttribute("opacity", "0.55")
      svg.appendChild(path)
    })

    // Nodes + labels
    nodes.forEach(n => {
      const y = yPos[n.id]
      const r = n.isCenter ? (expanded ? 8 : 6) : (expanded ? 5 : 4)
      const g = document.createElementNS(ns, "g")
      g.style.cursor = "pointer"
      g.addEventListener("click", () => this.pushEvent("node_selected", { id: n.id }))

      const circle = document.createElementNS(ns, "circle")
      circle.setAttribute("cx", spineX); circle.setAttribute("cy", y)
      circle.setAttribute("r", r); circle.setAttribute("fill", n.color)
      if (n.isCenter) {
        circle.setAttribute("stroke", "#1e40af"); circle.setAttribute("stroke-width", "2")
      }
      g.appendChild(circle)

      const text = document.createElementNS(ns, "text")
      text.setAttribute("x", spineX + r + 6); text.setAttribute("y", y + Math.round(fontSize * 0.35))
      text.setAttribute("font-size", fontSize); text.setAttribute("fill", "#6b7280")
      text.setAttribute("font-family", "ui-sans-serif, system-ui, sans-serif")
      text.setAttribute("dominant-baseline", "middle")
      text.textContent = n.label.length > maxLabel ? n.label.slice(0, maxLabel - 1) + "…" : n.label
      g.appendChild(text)

      svg.appendChild(g)
    })

    el.innerHTML = ""
    el.appendChild(svg)
    // Scroll sidebar to top so arc diagram is visible
    const sidebar = el.parentElement
    if (sidebar) sidebar.scrollTop = 0
  },

  _clearArcDiagram() {
    const el = document.getElementById("arc-diagram")
    if (el) el.innerHTML = ""
  },

  _openArcModal() {
    const modal = document.getElementById("arc-modal")
    if (!modal || !this._lastCenterId || !this._lastHoodSet) return
    modal.classList.remove("hidden")
    modal.classList.add("flex")
    // Re-attach close handler in case LiveView replaced the button
    const closeBtn = document.getElementById("arc-modal-close")
    if (closeBtn) closeBtn.onclick = () => this._closeArcModal()
    this._renderD3ArcDiagram()
  },

  _closeArcModal() {
    const modal = document.getElementById("arc-modal")
    if (!modal) return
    modal.classList.remove("flex")
    modal.classList.add("hidden")
    const body = document.getElementById("arc-modal-body")
    if (body) body.innerHTML = ""
  },

  _renderD3ArcDiagram() {
    const body = document.getElementById("arc-modal-body")
    if (!body || !this.graph || !this._lastHoodSet || !this._lastCenterId) return
    body.innerHTML = ""

    const centerId = this._lastCenterId
    const hoodSet = this._lastHoodSet

    // Build node list sorted by confidence descending
    const nodes = Array.from(hoodSet)
      .filter(id => this.graph.hasNode(id))
      .map(id => ({
        id,
        label: this.graph.getNodeAttribute(id, "label") || id,
        confidence: this.graph.getNodeAttribute(id, "confidence") ?? 1.0,
        isCenter: id === centerId,
      }))
      .sort((a, b) => b.confidence - a.confidence)

    // Build edge list within the hood
    const edges = []
    this.graph.forEachEdge((eid, attrs, source, target) => {
      if (hoodSet.has(source) && hoodSet.has(target)) {
        edges.push({
          source,
          target,
          certainty: attrs.certainty || "solid",
          label: attrs.label || "",
        })
      }
    })

    // Layout constants
    const nodeSpacing = 52
    const topPad = 32
    const svgH = topPad * 2 + nodeSpacing * Math.max(nodes.length - 1, 0)
    const svgW = body.clientWidth || 800
    const spineX = Math.round(svgW * 0.22)
    const ns = "http://www.w3.org/2000/svg"

    // D3 scales
    const yScale = scalePoint()
      .domain(nodes.map(n => n.id))
      .range([topPad, svgH - topPad])
      .padding(0)

    // Red → Yellow → Blue across observed confidence range [0.65, 1.0]
    const colorScale = scaleSequential(interpolateRdYlBu).domain([0.65, 1.0])

    // Convenience: y position by node id
    const yPos = {}
    nodes.forEach(n => { yPos[n.id] = yScale(n.id) })

    // Create SVG
    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("width", svgW)
    svg.setAttribute("height", svgH)
    svg.style.display = "block"

    // Spine
    const spine = document.createElementNS(ns, "line")
    spine.setAttribute("x1", spineX); spine.setAttribute("y1", topPad)
    spine.setAttribute("x2", spineX); spine.setAttribute("y2", svgH - topPad)
    spine.setAttribute("stroke", "#e2e8f0"); spine.setAttribute("stroke-width", "1")
    svg.appendChild(spine)

    // Arcs + edge labels
    edges.forEach(e => {
      const y1 = yPos[e.source], y2 = yPos[e.target]
      if (y1 === undefined || y2 === undefined) return
      const span = Math.abs(y2 - y1)
      const bow = Math.max(span * 0.42, 14)
      const mx = spineX - bow          // control point x
      const my = (y1 + y2) / 2        // midpoint y

      // Arc path using d3-path
      const p = d3path()
      p.moveTo(spineX, y1)
      p.bezierCurveTo(mx, y1, mx, y2, spineX, y2)

      const dashArr = e.certainty === "dashed" ? "6 3" : e.certainty === "dotted" ? "2 4" : null
      const arcEl = document.createElementNS(ns, "path")
      arcEl.setAttribute("d", p.toString())
      arcEl.setAttribute("fill", "none")
      arcEl.setAttribute("stroke", "#94a3b8")
      arcEl.setAttribute("stroke-width", "1.5")
      arcEl.setAttribute("opacity", "0.5")
      if (dashArr) arcEl.setAttribute("stroke-dasharray", dashArr)
      svg.appendChild(arcEl)

      // Edge label at arc midpoint (left of spine)
      if (e.label) {
        const maxLabelLen = 28
        const labelText = e.label.length > maxLabelLen ? e.label.slice(0, maxLabelLen - 1) + "…" : e.label
        const lbl = document.createElementNS(ns, "text")
        lbl.setAttribute("x", mx - 6)
        lbl.setAttribute("y", my)
        lbl.setAttribute("text-anchor", "end")
        lbl.setAttribute("dominant-baseline", "middle")
        lbl.setAttribute("font-size", "10")
        lbl.setAttribute("fill", "#94a3b8")
        lbl.setAttribute("font-family", "ui-sans-serif, system-ui, sans-serif")
        lbl.textContent = labelText
        svg.appendChild(lbl)
      }
    })

    // Nodes + labels
    nodes.forEach(n => {
      const y = yPos[n.id]
      const r = n.isCenter ? 9 : 6
      const color = colorScale(n.confidence)
      const g = document.createElementNS(ns, "g")
      g.style.cursor = "pointer"
      g.addEventListener("click", () => {
        this._closeArcModal()
        this.pushEvent("node_selected", { id: n.id })
      })

      // Circle
      const circle = document.createElementNS(ns, "circle")
      circle.setAttribute("cx", spineX); circle.setAttribute("cy", y)
      circle.setAttribute("r", r); circle.setAttribute("fill", color)
      if (n.isCenter) {
        circle.setAttribute("stroke", "#1e40af"); circle.setAttribute("stroke-width", "2.5")
      }
      g.appendChild(circle)

      // Node label (right of spine)
      const text = document.createElementNS(ns, "text")
      text.setAttribute("x", spineX + r + 10); text.setAttribute("y", y)
      text.setAttribute("dominant-baseline", "middle")
      text.setAttribute("font-size", "13")
      text.setAttribute("fill", "#374151")
      text.setAttribute("font-family", "ui-sans-serif, system-ui, sans-serif")
      text.textContent = n.label
      g.appendChild(text)

      // Confidence score (left of spine)
      const conf = document.createElementNS(ns, "text")
      conf.setAttribute("x", spineX - r - 8); conf.setAttribute("y", y)
      conf.setAttribute("text-anchor", "end")
      conf.setAttribute("dominant-baseline", "middle")
      conf.setAttribute("font-size", "10")
      conf.setAttribute("fill", "#94a3b8")
      conf.setAttribute("font-family", "ui-sans-serif, system-ui, sans-serif")
      conf.textContent = Math.round(n.confidence * 100) + "%"
      g.appendChild(conf)

      svg.appendChild(g)
    })

    body.appendChild(svg)
  },

  // Restore a neighborhood overlay that was saved with a named view.
  // Re-applies hide/dim state using the saved node set without re-running
  // _concentricLayout (positions are already correct from the saved view).
  _applyOverlayRestore(os) {
    if (!this.sigma || !this.graph) return
    const hoodSet = new Set((os.hoodNodeIds || []).filter(id => this.graph.hasNode(id)))
    if (!hoodSet.size || !this.graph.hasNode(os.centerNodeId)) {
      // Saved overlay is stale (nodes removed) — fall back to plain view
      this._fitView()
      return
    }
    this._selectedNode = os.centerNodeId
    this._exploredNodes = (os.exploredNodeIds || []).filter(id => this.graph.hasNode(id))
    this._trailNodes = new Set(this._exploredNodes.slice(0, -1))
    this._inOverlay = true
    this._overlayHidden = new Set()
    this._overlayHiddenEdges = new Set()
    this._dimmedNodes = new Set()
    this._dimmedEdges = new Set()
    this.graph.forEachNode((id) => {
      if (!hoodSet.has(id)) this._overlayHidden.add(id)
    })
    this.graph.forEachEdge((id, _attrs, source, target) => {
      if (!hoodSet.has(source) || !hoodSet.has(target)) this._overlayHiddenEdges.add(id)
    })
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
    const min = this._minDegree
    this.graph.forEachNode((id) => {
      const deg = this.graph.degree(id)
      if ((min > 1 && deg < min) || (this._hideIsolated && deg === 0)) {
        this._hiddenNodes.add(id)
      }
    })
    this.graph.forEachEdge((id, _attrs, source, target) => {
      if (this._hiddenNodes.has(source) || this._hiddenNodes.has(target)) {
        this._hiddenEdges.add(id)
      }
    })
    // Color nodes based on visible connectivity; mark isolated for ring placement.
    // Sphere nodes change color only (no type switch); dark-red tints the sphere texture.
    this.graph.forEachNode((id) => {
      if (this._hiddenNodes.has(id)) return
      const hasVisibleEdge = this.graph.someEdge(id, (eid) => !this._hiddenEdges.has(eid))
      const isolated = !hasVisibleEdge
      this.graph.setNodeAttribute(id, "_isolated", isolated)
      this.graph.setNodeAttribute(id, "_color",
        isolated
          ? "#dc2626"  // dark red — tints the sphere texture red
          : confidenceColor(this.graph.getNodeAttribute(id, "confidence") ?? 1.0)
      )
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

  // Position the tooltip div near the current cursor, flipping left if needed.
  _positionTooltip(tip) {
    const tipW = 260
    const containerW = this.el.offsetWidth
    const containerH = this.el.offsetHeight
    const x = this._mouseX
    const y = this._mouseY
    const tx = (x + 18 + tipW > containerW) ? x - tipW - 12 : x + 18
    const ty = Math.min(y + 12, containerH - 80)
    tip.style.left = `${tx}px`
    tip.style.top  = `${ty}px`
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
      // Current node: show full summary text (wrapping); trail nodes: truncate.
      text.style.cssText = isCurrent
        ? "white-space:normal;word-break:break-word;line-height:1.35;"
        : "overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
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
        semanticType: d.type,
        node_type: d.node_type || "claim",
        // Synthesis nodes use the piechart renderer; all others use the sphere.
        type: isSynthesis ? "piechart" : "sphere",
        slice_a: isSynthesis ? 1 : 0,
        slice_b: isSynthesis ? 1 : 0,
        _isolated: false,
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
      this.graph.setNodeAttribute(id, "_color", confidenceColor(this.graph.getNodeAttribute(id, "confidence") ?? 1.0))
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
      enableEdgeClickEvents: true,
      enableEdgeHoverEvents: true,  // needed for click detection to work reliably
      nodeProgramClasses: { piechart: NodePiechartProgram, sphere: NodeSphereProgram },
      nodeReducer: (id, attrs) => this._nodeReducer(id, attrs, colors),
      edgeReducer: (id, attrs) => this._edgeReducer(id, attrs, colors),
      defaultDrawNodeLabel: (context, data, settings) => {
        if (!data.label) return
        const size   = settings.labelSize
        const font   = settings.labelFont
        const weight = settings.labelWeight
        context.font = `${weight} ${size}px ${font}`

        const textW   = context.measureText(data.label).width
        const pad     = 3
        const x       = data.x + data.size + 3
        const y       = data.y + size / 3
        const boxX    = x - pad
        const boxY    = y - size * 0.82 - pad
        const boxW    = textW + pad * 2
        const boxH    = size * 1.1 + pad * 2

        context.fillStyle = "rgba(255, 255, 255, 0.88)"
        context.beginPath()
        context.roundRect(boxX, boxY, boxW, boxH, 3)
        context.fill()

        context.fillStyle = "#222"
        context.fillText(data.label, x, y)
      },
    })

    this._initBoxSelect()

    // Events
    this.sigma.on("clickEdge", ({edge}) => {
      if (this._didDrag) return
      this._activateEdge(edge)
    })

    this.sigma.on("clickNode", ({node}) => {
      if (this._didDrag) { this._didDrag = false; return }  // consumed: drag just ended
      this._dismissEdgeSelection()
      const currentCenter = this._exploredNodes[this._exploredNodes.length - 1]
      const prevIdx = this._exploredNodes.indexOf(node)
      if (prevIdx !== -1 && node !== currentCenter) {
        this.pushEvent("unwind_to", {id: node})
      } else {
        this.pushEvent("node_selected", {id: node})
      }
    })

    this.sigma.on("clickStage", () => {
      if (this._selectedEdge) { this._dismissEdgeSelection(); return }
      // Manual fallback: check if click landed near an edge (Sigma's built-in
      // edge picking can miss thin edges in some versions/programs)
      const edgeId = this._findEdgeAtPoint(this._mouseX, this._mouseY)
      if (edgeId) { this._activateEdge(edgeId); return }
      this.pushEvent("deselect", {})
    })

    this.sigma.on("enterNode", ({node}) => {
      if (this._selectedEdge) return  // edge popup has priority
      this._highlightedNode = node
      this._hoveredNeighbors = new Set(this.graph.neighbors(node))
      this._hoveredEdges = new Set()
      this.graph.forEachEdge(node, (id) => this._hoveredEdges.add(id))
      const attrs = this.graph.getNodeAttributes(node)
      const label = attrs.label || node
      const conf = attrs.confidence ?? 1.0
      const pct = Math.round(conf * 100)
      const tip = document.getElementById("node-tooltip")
      if (tip) {
        tip.innerHTML =
          `<p style="font-weight:500;line-height:1.4;">${escHtml(label)}</p>` +
          `<div style="display:flex;align-items:center;gap:6px;margin-top:6px;padding-top:6px;border-top:1px solid rgba(128,128,128,0.2)">` +
            `<span style="font-size:11px;opacity:0.5;white-space:nowrap">Confidence</span>` +
            `<div style="flex:1;height:4px;border-radius:2px;background:rgba(128,128,128,0.2);overflow:hidden">` +
              `<div style="height:100%;border-radius:2px;background:var(--color-primary);width:${pct}%"></div>` +
            `</div>` +
            `<span style="font-size:11px;opacity:0.6;font-variant-numeric:tabular-nums">${pct}%</span>` +
          `</div>`
        this._positionTooltip(tip)
        tip.style.display = "block"
      }
      this.sigma.refresh()
    })

    this.sigma.on("leaveNode", () => {
      if (this._selectedEdge) return  // edge popup stays until explicit dismiss
      this._highlightedNode = null
      this._hoveredNeighbors = new Set()
      this._hoveredEdges = new Set()
      const tip = document.getElementById("node-tooltip")
      if (tip) { tip.style.display = "none"; tip.innerHTML = "" }
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
      this._onLayoutDone(true)
      return
    }

    // Named-view positions were pre-loaded into the graph in the graph_loaded handler.
    // Skip auto-save restoration and FA2 — positions are already correct.
    if (this._skipLayout) {
      this._skipLayout = false
      this._onLayoutDone(true)
      return
    }

    // Priority 1: auto-save (transparent single slot, persists across filter changes).
    const saved = this._loadSavedLayout()
    if (saved) {
      let restored = 0
      this.graph.forEachNode((id) => {
        if (saved[id]) {
          this.graph.setNodeAttribute(id, "x", saved[id].x)
          this.graph.setNodeAttribute(id, "y", saved[id].y)
          restored++
        }
      })
      if (restored > 0) {
        this._onLayoutDone(true)  // skip placement — saved positions already include ring/separation
        return
      }
    }

    // Priority 3: ForceAtlas2 for all sizes — scale iterations down for large graphs.
    const iterations = nodeCount > 500 ? 30 : nodeCount > 150 ? 80 : 300
    const fa2Settings = forceAtlas2.inferSettings(this.graph)
    forceAtlas2.assign(this.graph, {
      iterations,
      settings: { ...fa2Settings, scalingRatio: fa2Settings.scalingRatio * 1.2 },
    })
    this._onLayoutDone()
  },

  _layoutStorageKey() {
    return this._graphId ? `sigma_layout:${this._graphId}` : null
  },

  _loadSavedLayout() {
    const key = this._layoutStorageKey()
    if (!key) return null
    try {
      const raw = localStorage.getItem(key)
      return raw ? JSON.parse(raw) : null
    } catch { return null }
  },

  // ---------------------------------------------------------------------------
  // Auto-save (single slot) — transparent background persistence.
  // Preserves layout across filter/degree changes without user action.
  // ---------------------------------------------------------------------------

  _persistAutoSave() {
    const key = this._layoutStorageKey()
    if (!key || !this.graph) return
    const positions = {}
    this.graph.forEachNode((id) => {
      positions[id] = {
        x: this.graph.getNodeAttribute(id, "x"),
        y: this.graph.getNodeAttribute(id, "y"),
      }
    })
    try { localStorage.setItem(key, JSON.stringify(positions)) }
    catch (e) { console.warn("auto-save failed", e) }
  },

  _resetLayout() {
    const key = this._layoutStorageKey()
    if (key) localStorage.removeItem(key)
    this._pendingViewId = null
    this.graph.forEachNode((id) => {
      this.graph.setNodeAttribute(id, "x", (Math.random() - 0.5) * 500)
      this.graph.setNodeAttribute(id, "y", (Math.random() - 0.5) * 500)
    })
    this._runLayout(this.graph.order)
  },

  // ---------------------------------------------------------------------------
  // Named saved views
  // ---------------------------------------------------------------------------

  _savesStorageKey() {
    return this._graphId ? `sigma_saves:${this._graphId}` : null
  },

  _listSaves() {
    const key = this._savesStorageKey()
    if (!key) return []
    try { return JSON.parse(localStorage.getItem(key) || "[]") }
    catch { return [] }
  },

  _persistSaves(saves) {
    const key = this._savesStorageKey()
    if (!key) return
    try { localStorage.setItem(key, JSON.stringify(saves)) }
    catch (e) { console.warn("saves persist failed", e) }
  },

  _saveView(name) {
    const saves = this._listSaves()
    if (saves.length >= 20) {
      this._showToast("20 saved views — delete one before saving again.", "warning")
      return
    }
    const positions = {}
    this.graph.forEachNode((id) => {
      positions[id] = {
        x: this.graph.getNodeAttribute(id, "x"),
        y: this.graph.getNodeAttribute(id, "y"),
      }
    })
    // Capture neighborhood overlay state so loading restores the full view.
    // hoodNodeIds = every node that is currently visible (not overlay-hidden).
    let overlayState = null
    if (this._inOverlay && this._selectedNode) {
      const hoodNodeIds = []
      this.graph.forEachNode(id => { if (!this._overlayHidden.has(id)) hoodNodeIds.push(id) })
      overlayState = {
        centerNodeId: this._selectedNode,
        exploredNodeIds: [...this._exploredNodes],
        hoodNodeIds,
      }
    }
    const save = {
      id: `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
      name: name.slice(0, 80),
      savedAt: new Date().toISOString(),
      positions,
      minDegree: this._minDegree,
      layer: this._currentLayer,
      type: this._currentType,
      overlayState,
    }
    saves.unshift(save)  // newest first
    this._persistSaves(saves)
    this._persistAutoSave()  // keep auto-save in sync with the named view
    this._renderSavedViewsPanel()
    this._showToast(`Saved "${save.name}"`, "success")
  },

  _deleteView(id) {
    const saves = this._listSaves().filter(s => s.id !== id)
    this._persistSaves(saves)
    this._renderSavedViewsPanel()
  },

  _loadView(id) {
    const save = this._listSaves().find(s => s.id === id)
    if (!save) return
    this._pendingViewId = id
    this.pushEvent("load_saved_view", {
      min_degree: save.minDegree,
      layer: save.layer || "all",
      type: save.type || "all",
    })
  },

  _renderSavedViewsPanel() {
    const list  = document.getElementById("cy-saves-list")
    const count = document.getElementById("cy-saves-count")
    if (!list) return
    const readOnly = this.el.dataset.readOnly === "true"
    const saves = this._listSaves()
    if (count) count.textContent = `${saves.length} of 20`
    if (saves.length === 0) {
      list.innerHTML = '<p class="text-xs text-base-content/30 italic px-2 py-1">No saved views yet.</p>'
      return
    }
    list.innerHTML = saves.map(s => {
      const date = new Date(s.savedAt).toLocaleDateString(undefined, { month: "short", day: "numeric" })
      const name = escHtml(s.name)
      const deleteBtn = readOnly ? "" : `
          <button data-delete-view="${s.id}"
            class="opacity-0 group-hover/item:opacity-100 text-error hover:bg-error/10 rounded px-1.5 py-1 text-sm leading-none transition-all shrink-0"
            title="Delete">×</button>`
      return `
        <div class="flex items-center gap-1 group/item rounded hover:bg-base-200 transition-colors">
          <button data-load-view="${s.id}"
            class="flex-1 min-w-0 text-left text-xs truncate px-2 py-1.5"
            title="${name}">${name}</button>
          <span class="text-xs text-base-content/30 shrink-0 pr-1 tabular-nums">${date}</span>
          ${deleteBtn}
        </div>`
    }).join("")
  },

  _showSaveViewDialog() {
    const dialog = document.getElementById("cy-save-view-dialog")
    const input  = document.getElementById("cy-save-view-name")
    if (!dialog || !input) return
    input.value = this._smartSaveName()
    dialog.style.display = "block"
    input.focus()
    input.select()
    // Dismiss on outside click (defer so this click doesn't immediately close it)
    this._dismissSaveDialog = (e) => {
      if (!dialog.contains(e.target) && e.target.id !== "cy-save-view-btn")
        this._hideSaveViewDialog()
    }
    setTimeout(() => document.addEventListener("click", this._dismissSaveDialog), 0)
  },

  _hideSaveViewDialog() {
    const dialog = document.getElementById("cy-save-view-dialog")
    if (dialog) dialog.style.display = "none"
    if (this._dismissSaveDialog) {
      document.removeEventListener("click", this._dismissSaveDialog)
      this._dismissSaveDialog = null
    }
  },

  _smartSaveName() {
    // 1. Label of the most recently explored node
    if (this._exploredNodes.length > 0) {
      const id = this._exploredNodes[this._exploredNodes.length - 1]
      const label = this.graph && this.graph.hasNode(id)
        ? this.graph.getNodeAttribute(id, "label")
        : null
      if (label) return label.slice(0, 60)
    }
    // 2. Current focus textarea value
    const focusInput = document.querySelector('textarea[name="prompt"]')
    if (focusInput && focusInput.value.trim()) return focusInput.value.trim().slice(0, 60)
    // 3. Date fallback
    return `View ${new Date().toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" })}`
  },

  _showToast(msg, type = "info") {
    const colors = {
      success: "bg-success text-success-content",
      warning: "bg-warning text-warning-content",
      info:    "bg-base-200 text-base-content",
    }
    const el = document.createElement("div")
    el.className = `fixed bottom-16 right-4 z-50 rounded-lg px-3 py-2 text-xs font-medium shadow-lg ${colors[type] || colors.info}`
    el.style.transition = "opacity 0.3s"
    el.textContent = msg
    document.body.appendChild(el)
    setTimeout(() => { el.style.opacity = "0"; setTimeout(() => el.remove(), 300) }, 2200)
  },

  // Post-FA2 overlap removal. FA2 works in abstract graph-space coordinates while Sigma
  // renders nodes at screen-pixel sizes — adjustSizes can't bridge this gap because the
  // two coordinate systems are unrelated. Instead, after FA2 we compute the graph→screen
  // scale factor from the bounding box, convert each node's pixel radius into graph-space
  // units, and run an iterative spring-push until no two nodes visually overlap.
  _removeOverlaps() {
    if (!this.graph || this.graph.order < 2) return

    // Use the live camera to get the true graph→screen scale.
    // graphToViewport maps a graph-space point to a CSS-pixel viewport point.
    // Comparing two points 1 unit apart gives us px-per-graph-unit.
    const p0 = this.sigma.graphToViewport({ x: 0, y: 0 })
    const p1 = this.sigma.graphToViewport({ x: 1, y: 0 })
    const pxPerUnit = Math.max(Math.abs(p1.x - p0.x), 0.001)
    const graphUnitsPerPx = 1 / pxPerUnit

    const nodes = []
    this.graph.forEachNode((id, attrs) => {
      if (this._hiddenNodes.has(id)) return  // skip degree-filtered nodes
      // +5 px gap so adjacent nodes have a comfortable visual margin
      nodes.push({ id, x: attrs.x, y: attrs.y, r: ((attrs._size || 8) + 5) * graphUnitsPerPx })
    })

    for (let pass = 0; pass < 80; pass++) {
      let moved = false
      for (let i = 0; i < nodes.length; i++) {
        for (let j = i + 1; j < nodes.length; j++) {
          const a = nodes[i], b = nodes[j]
          const dx = b.x - a.x || 0.001
          const dy = b.y - a.y
          const dist = Math.sqrt(dx * dx + dy * dy) || 0.001
          const minDist = a.r + b.r
          if (dist < minDist) {
            moved = true
            // 1.05 overshoot helps dense clusters converge in fewer outer passes
            const push = ((minDist - dist) / 2) * 1.05
            const nx = dx / dist, ny = dy / dist
            a.x -= nx * push; a.y -= ny * push
            b.x += nx * push; b.y += ny * push
          }
        }
      }
      if (!moved) break
    }

    nodes.forEach(({ id, x, y }) => {
      this.graph.setNodeAttribute(id, "x", x)
      this.graph.setNodeAttribute(id, "y", y)
    })
  },

  // Place visually-isolated nodes (type:"isolated", set by _applyDegreeFilter) on a
  // ring around the connected component.  Catches both graphology degree-0 nodes and
  // nodes whose edges are all hidden by the current degree filter.
  _placeIsolatedNodes() {
    const isolated = []
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity

    this.graph.forEachNode((id) => {
      if (this._hiddenNodes.has(id)) return
      if (this.graph.getNodeAttribute(id, "_isolated")) {
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

  // ---------------------------------------------------------------------------
  // Box-select zoom — Alt+drag to draw a rubber-band rectangle, release to zoom
  // ---------------------------------------------------------------------------
  _initBoxSelect() {
    // Overlay div sits on top of the Sigma canvas; transparent to mouse normally.
    const overlay = document.createElement("div")
    overlay.style.cssText = "position:absolute;inset:0;pointer-events:none;cursor:crosshair;z-index:10;"
    const band = document.createElement("div")
    band.style.cssText = "position:absolute;border:2px dashed rgba(255,255,255,0.85);background:rgba(255,255,255,0.07);display:none;pointer-events:none;box-sizing:border-box;"
    overlay.appendChild(band)
    this.el.appendChild(overlay)
    this._boxOverlay = overlay
    this._boxBand    = band
    this._boxStart   = null
    this._boxActive  = false

    // Enable/disable overlay on Alt key.
    this._onBoxKeyDown = (e) => {
      if (e.key === "Alt" && !this._boxActive) overlay.style.pointerEvents = "all"
    }
    this._onBoxKeyUp = (e) => {
      if (e.key === "Alt" && !this._boxActive) overlay.style.pointerEvents = "none"
    }
    document.addEventListener("keydown", this._onBoxKeyDown)
    document.addEventListener("keyup",   this._onBoxKeyUp)

    // Mousedown: begin selection.
    overlay.addEventListener("mousedown", (e) => {
      if (!e.altKey) { overlay.style.pointerEvents = "none"; return }
      e.preventDefault()
      this._boxActive = true
      const r = this.el.getBoundingClientRect()
      this._boxStart = { x: e.clientX - r.left, y: e.clientY - r.top }
      band.style.cssText = band.style.cssText.replace("display:none", "display:block")
      band.style.display = "block"
      band.style.left = this._boxStart.x + "px"
      band.style.top  = this._boxStart.y + "px"
      band.style.width = "0px"
      band.style.height = "0px"
    })

    // Mousemove: update rectangle (document-level so dragging outside el works).
    this._onBoxMove = (e) => {
      if (!this._boxActive || !this._boxStart) return
      const r = this.el.getBoundingClientRect()
      const cx = e.clientX - r.left
      const cy = e.clientY - r.top
      band.style.left   = Math.min(this._boxStart.x, cx) + "px"
      band.style.top    = Math.min(this._boxStart.y, cy) + "px"
      band.style.width  = Math.abs(cx - this._boxStart.x) + "px"
      band.style.height = Math.abs(cy - this._boxStart.y) + "px"
    }
    document.addEventListener("mousemove", this._onBoxMove)

    // Mouseup: zoom to selection.
    this._onBoxUp = (e) => {
      if (!this._boxActive || !this._boxStart) return
      this._boxActive = false
      band.style.display = "none"
      overlay.style.pointerEvents = "none"
      const r = this.el.getBoundingClientRect()
      const cx = e.clientX - r.left
      const cy = e.clientY - r.top
      const x0 = Math.min(this._boxStart.x, cx)
      const y0 = Math.min(this._boxStart.y, cy)
      const x1 = Math.max(this._boxStart.x, cx)
      const y1 = Math.max(this._boxStart.y, cy)
      this._boxStart = null
      if (x1 - x0 < 8 || y1 - y0 < 8) return  // misclick — ignore tiny selections
      // sigma.viewportToGraph() returns raw graph coords, but camera.animate() needs
      // framed/normalized coords (the space camera.x/y live in).  Compute directly from
      // the current camera state instead.
      const cam   = this.sigma.getCamera()
      const cs    = cam.getState()                          // {x, y, ratio}
      const cw    = this._container.offsetWidth  || 800
      const ch    = this._container.offsetHeight || 600
      const scale = Math.min(cw, ch)                        // Sigma's reference dimension (NOT /2)
      // Invert the camera projection: viewport px → framed graph coords.
      // Sigma's framed Y axis is inverted relative to screen Y (positive Y = up in graph).
      const toFramed = (vx, vy) => ({
        x: cs.x + (vx - cw / 2) * cs.ratio / scale,
        y: cs.y - (vy - ch / 2) * cs.ratio / scale,
      })
      // Center: convert the selection's midpoint to framed coords.
      const fc    = toFramed((x0 + x1) / 2, (y0 + y1) / 2)
      // Ratio: the selection covers (selW/cw) of viewport width and (selH/ch) of height.
      // New ratio = current ratio × that fraction, so the selection fills the canvas.
      const selW  = x1 - x0
      const selH  = y1 - y0
      const ratio = cs.ratio * Math.max(selW / cw, selH / ch) * 1.05
      cam.animate({ x: fc.x, y: fc.y, ratio }, { duration: 250 })
    }
    document.addEventListener("mouseup", this._onBoxUp)
  },

  _onLayoutDone(skipPlacement = false) {
    this._layoutDone = true
    this._applyDegreeFilter()
    // Only re-place isolated nodes and separate components when positions came from FA2.
    // When restoring saved positions the layout is already correct — re-running placement
    // would overwrite the saved ring/component positions with freshly-calculated ones.
    if (!skipPlacement) {
      this._placeIsolatedNodes()
      this._separateComponents()
    }
    this._hideOverlay()
    this.sigma.refresh()
    this._updateStats()
    // Defer fit: getNodeDisplayData is only populated after Sigma's first render pass.
    // Overlap removal also runs here so it can use the real camera scale.
    setTimeout(() => {
      if (this._pendingOverlayRestore) {
        const os = this._pendingOverlayRestore
        this._pendingOverlayRestore = null
        this._applyOverlayRestore(os)
      } else {
        this._fitView()
        this._applyPendingOverlay()
      }
      if (!skipPlacement) {
        this._removeOverlaps()
        this.sigma.refresh()
        this._fitView()           // re-fit after nodes spread out
        this._persistAutoSave()
      }
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

  _activateEdge(edge) {
    this._selectedEdge = edge
    const source = this.graph.source(edge)
    const target = this.graph.target(edge)
    this._edgeHighlightedNodes = new Set([source, target])
    this._highlightedNode = null
    this._hoveredNeighbors = new Set()
    this._hoveredEdges = new Set()

    const a = this.graph.getEdgeAttributes(edge)
    const srcLabel = this.graph.getNodeAttribute(source, "label") || source
    const tgtLabel = this.graph.getNodeAttribute(target, "label") || target
    const pct = Math.round((a.confidence ?? 0.5) * 100)
    const certaintyIcon = { solid: "—", dashed: "- -", dotted: "···" }[a.certainty] || "—"

    const tip = document.getElementById("node-tooltip")
    if (tip) {
      tip.innerHTML =
        `<p style="font-size:11px;opacity:0.5;margin-bottom:4px;text-transform:uppercase;letter-spacing:.05em">${escHtml(a.type || "relates")} ${certaintyIcon}${a.cross_graph ? " · cross-graph" : ""}</p>` +
        `<p style="line-height:1.5;font-size:12px;">${escHtml(srcLabel)}</p>` +
        `<p style="line-height:1.5;font-size:12px;opacity:0.5">↓</p>` +
        `<p style="line-height:1.5;font-size:12px;">${escHtml(tgtLabel)}</p>` +
        `<div style="display:flex;align-items:center;gap:6px;margin-top:6px;padding-top:6px;border-top:1px solid rgba(128,128,128,0.2)">` +
          `<span style="font-size:11px;opacity:0.5;white-space:nowrap">Confidence</span>` +
          `<div style="flex:1;height:4px;border-radius:2px;background:rgba(128,128,128,0.2);overflow:hidden">` +
            `<div style="height:100%;border-radius:2px;background:var(--color-primary);width:${pct}%"></div>` +
          `</div>` +
          `<span style="font-size:11px;opacity:0.6;font-variant-numeric:tabular-nums">${pct}%</span>` +
        `</div>`
      this._positionTooltip(tip)
      tip.style.display = "block"
    }
    this.sigma.refresh()
  },

  _dismissEdgeSelection() {
    if (!this._selectedEdge) return
    this._selectedEdge = null
    this._edgeHighlightedNodes = new Set()
    const tip = document.getElementById("node-tooltip")
    if (tip) { tip.style.display = "none"; tip.innerHTML = "" }
    this.sigma.refresh()
  },

  // Find the closest visible edge to (px, py) in container pixels.
  // Uses sigma.graphToViewport() for coordinate conversion.
  // Returns edge id or null if nothing within threshold pixels.
  _findEdgeAtPoint(px, py) {
    const THRESHOLD = 8
    let bestId = null
    let bestDist = THRESHOLD
    this.graph.forEachEdge((id, _attrs, source, target) => {
      if (this._hiddenEdges.has(id) || this._overlayHiddenEdges.has(id)) return
      const sx = this.graph.getNodeAttribute(source, "x")
      const sy = this.graph.getNodeAttribute(source, "y")
      const tx = this.graph.getNodeAttribute(target, "x")
      const ty = this.graph.getNodeAttribute(target, "y")
      const sp = this.sigma.graphToViewport({x: sx, y: sy})
      const tp = this.sigma.graphToViewport({x: tx, y: ty})
      const dist = pointToSegDist(px, py, sp.x, sp.y, tp.x, tp.y)
      if (dist < bestDist) { bestDist = dist; bestId = id }
    })
    return bestId
  },

  // nodeReducer: called by Sigma on every render pass for each node.
  // Returns the display attributes for that node based on current state.
  _nodeReducer(id, attrs, colors) {
    // Show labels when few nodes are currently visible.
    // Use visible count (total minus degree-filtered and overlay-hidden) so the
    // label threshold responds to degree filters and neighborhood hopping, not
    // just total graph size.
    const visibleCount = this.graph.order - this._hiddenNodes.size - this._overlayHidden.size
    const labelText = visibleCount <= 10
      ? (() => { const s = attrs.label || ""; return s.length > 28 ? s.slice(0, 25) + "…" : s })()
      : undefined

    const result = {
      x: attrs.x,
      y: attrs.y,
      size: attrs._size || 8,
      color: attrs._color || colors.neutral,
      type: attrs.type,        // "sphere" (regular/isolated) or "piechart" (synthesis)
      slice_a: attrs.slice_a,  // piechart slices for synthesis nodes
      slice_b: attrs.slice_b,
      hidden: false,
      label: labelText,
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

    // Edge selection: highlight the two endpoint nodes
    if (this._selectedEdge) {
      if (this._edgeHighlightedNodes.has(id)) {
        result.color = "#f59e0b"
        result.size = result.size + 5
        result.zIndex = 25
      }
      return result
    }

    // Trail nodes (previous exploration centers) — violet
    if (this._trailNodes.has(id)) {
      result.color = "#8b5cf6"
      result.size = result.size + 3
      result.zIndex = 20
      return result
    }

    // Selected node — keep confidence color, just enlarge
    if (id === this._selectedNode) {
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
    const confidence = attrs.confidence ?? 0.5
    // Opacity: low-confidence edges fade to 25%, high-confidence stay fully visible.
    const alpha = Math.round((0.25 + confidence * 0.75) * 255).toString(16).padStart(2, "0")
    const certaintyColor = { solid: "#5a9e6f", dashed: "#a07830", dotted: "#f87171" }[attrs.certainty] ?? "#6b7280"
    const result = {
      color: certaintyColor + alpha,
      size: 0.5 + confidence * 2,
      hidden: false,
      zIndex: 5,
    }

    if (attrs.cross_graph) result.color = "#f59e0b" + alpha

    // Degree filter
    if (this._hiddenEdges.has(id)) { result.hidden = true; return result }

    // Edge click: highlight selected edge prominently
    if (this._selectedEdge === id) {
      result.color = certaintyColor + "ff"
      result.size = 4
      result.zIndex = 50
      return result
    }

    // Overlay visibility
    if (this._overlayHiddenEdges.has(id)) { result.hidden = true; return result }

    // Focus dimming
    if (this._dimmedEdges.has(id)) {
      result.color = certaintyColor + "30"
      result.size = 0.5
      result.zIndex = 0
      return result
    }

    // Hover highlight
    if (this._hoveredEdges.has(id)) {
      result.color = certaintyColor + "ff"
      result.size = 3
      result.zIndex = 40
    }

    return result
  },
}

// Distance from point (px,py) to line segment (ax,ay)→(bx,by), in pixels.
function pointToSegDist(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay
  const lenSq = dx * dx + dy * dy
  if (lenSq === 0) return Math.hypot(px - ax, py - ay)
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy))
}


// Escape HTML special chars for safe insertion into innerHTML strings.
function escHtml(str) {
  return String(str).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function sigmaNodeSize(deg) {
  // Minimum 5 so isolated (0-edge) nodes are visible; wider range for better visual hierarchy.
  return 5 + Math.log1p(deg) * 4.0
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
  // Blue range: 214° hue. Sky-blue (low degree) → deep royal blue (high degree).
  const lightness = Math.round(72 - t * 32)
  return hslToHex(214, 80, lightness)
}

// Confidence-based node color: normalize within observed range [0.65, 1.0],
// split into three equal bands: red (low) → yellow (mid) → blue (high).
function confidenceColor(confidence) {
  const MIN = 0.65, MAX = 1.0
  const norm = Math.max(0, Math.min(1, (confidence - MIN) / (MAX - MIN)))
  if (norm < 1 / 3) return "#f87171"  // red-400
  if (norm < 2 / 3) return "#fbbf24"  // amber-400
  return "#60a5fa"                     // blue-400
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

