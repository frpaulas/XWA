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
import cytoscape from "cytoscape"
import fcose from "cytoscape-fcose"

cytoscape.use(fcose)

// ---------------------------------------------------------------------------
// Cytoscape graph hook
// ---------------------------------------------------------------------------
const CytoscapeGraph = {
  mounted() {
    this._layoutDone = false
    this._pendingNeighborhood = null
    this._pendingFocus = null
    this._exploredNodes = []  // ordered array of center IDs, oldest first
    this._minDegree = 1
    this._inOverlay = false       // true while showing neighborhood or focus overlay
    this._applyingOverlay = false // re-entrancy guard
    // Mount Cytoscape on a stable child div, not this.el directly.
    // LiveView patches this.el's attributes on updates but never touches its children,
    // so the canvas elements survive across LiveView re-renders.
    this._cyContainer = document.createElement("div")
    this._cyContainer.style.cssText = "position:absolute;top:0;right:0;bottom:0;left:0;overflow:hidden;"
    this.el.appendChild(this._cyContainer)

    // Listen for graph data pushed from the server after async load or filter change
    this.handleEvent("graph_loaded", (data) => {
      if (this.cy) {
        this.cy.destroy()
        this.cy = null
      }
      this._layoutDone = false
      this._pendingNeighborhood = null
      this._pendingFocus = null
      this._exploredNodes = []
      this._minDegree = data.min_degree || 1
      this._inOverlay = false
      this._applyingOverlay = false
      if (data.full_reload) this._showOverlay()
      this.initCy(data)
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
        // Focus mode is mutually exclusive with neighborhood
        this._pendingNeighborhood = null
        if (this._layoutDone) this._applyPendingOverlay()
      }
      // If focus is empty, leave neighborhood state untouched — neighborhood_changed owns that
    })

    // Initial render: start with whatever data-graph holds (may be empty on async load)
    const initialData = JSON.parse(this.el.dataset.graph)
    if (initialData.nodes && initialData.nodes.length > 0) {
      this.initCy(initialData)
    }
    // Otherwise wait for "graph_loaded" event
  },

  updated() {
    // Neighborhood, focus, and graph data are all delivered via push_event / handleEvent.
    // Nothing to do on DOM attribute updates.
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this.cy) this.cy.destroy()
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
    if (!this.cy) return
    if (this._applyingOverlay) return
    this._applyingOverlay = true
    try {
      if (this._pendingFocus) {
        this._inOverlay = true
        this.cy.elements().unselect()
        this._applyFocusMode(this._pendingFocus)
      } else if (this._pendingNeighborhood) {
        const n = this._pendingNeighborhood
        const hoodSet = new Set(n.ids || [])
        hoodSet.add(n.center_id)
        this.cy.elements().unselect()
        const existingIdx = this._exploredNodes.indexOf(n.center_id)
        if (existingIdx !== -1) {
          // Keep this node as the current (last) entry; drop everything after it
          this._exploredNodes = this._exploredNodes.slice(0, existingIdx + 1)
        } else {
          this._exploredNodes.push(n.center_id)
        }
        this._pendingNeighborhood = null  // clear before _applyNeighborhood to prevent re-entrant layoutstop re-apply
        this._inOverlay = true
        this._applyNeighborhood(hoodSet, n.center_id)
        const centerNode = this.cy.getElementById(n.center_id)
        if (centerNode.length) centerNode.select()
      } else if (this._inOverlay) {
        // Only restore full graph if we were actually showing an overlay.
        // This prevents a spurious "restore" when _applyPendingOverlay is called
        // with nothing pending after the initial layout completes.
        this._inOverlay = false
        this._exploredNodes = []
        this._renderExploredLabels()
        this.cy.elements().unselect()
        this.cy.elements().removeStyle("opacity display background-color border-color border-width")
        this._applyDegreeFilter()
        this.cy.fit(80)
      }
    } finally {
      this._applyingOverlay = false
    }
  },

  _applyNeighborhood(hoodSet, centerId) {
    this.cy.nodes().forEach(n => {
      n.style({display: hoodSet.has(n.id()) ? "element" : "none"})
    })
    this.cy.edges().forEach(e => {
      const inHood = hoodSet.has(e.source().id()) && hoodSet.has(e.target().id())
      e.style({display: inHood ? "element" : "none"})
    })
    const hoodEles = this.cy.elements().filter(ele => {
      if (ele.isNode()) return hoodSet.has(ele.id())
      return hoodSet.has(ele.source().id()) && hoodSet.has(ele.target().id())
    })
    if (!hoodEles.length) return

    // Concentric layout — center node has highest local degree so lands at center.
    const hoodNodeIds = new Set(hoodEles.nodes().map(n => n.id()))
    hoodEles.layout({
      name: "concentric",
      animate: false,
      fit: true,
      padding: 60,
      startAngle: 3 / 2 * Math.PI,
      clockwise: true,
      equidistant: false,
      minNodeSpacing: 20,
      concentric: (node) => node.connectedEdges().filter(e =>
        hoodNodeIds.has(e.source().id()) && hoodNodeIds.has(e.target().id())
      ).length,
      levelWidth: () => 2,
    }).run()

    this.cy.fit(hoodEles, 60)

    // Mark previous centers purple and force them visible even if not in hoodSet.
    // They need to be shown so the user can see and tap the back-path.
    this._exploredNodes.forEach(id => {
      if (id === centerId) return
      const node = this.cy.getElementById(id)
      if (!node.length) return
      node.style({
        "display": "element",
        "background-color": "#8b5cf6",
        "border-color": "#8b5cf6",
        "border-width": 3,
        "opacity": 1,
      })
      // Also show edges connecting this back-node to the current hood
      node.connectedEdges().forEach(e => {
        const otherId = e.source().id() === id ? e.target().id() : e.source().id()
        if (hoodSet.has(otherId)) e.style({display: "element"})
      })
    })

    this._renderExploredLabels()
  },

  _applyDegreeFilter() {
    if (!this.cy || this._minDegree <= 1) return
    const min = this._minDegree
    this.cy.nodes().forEach(n => {
      const deg = n.degree()
      n.style({display: deg >= min ? "element" : "none"})
    })
    this.cy.edges().forEach(e => {
      const show = e.source().style("display") !== "none" && e.target().style("display") !== "none"
      e.style({display: show ? "element" : "none"})
    })
  },

  _renderExploredLabels() {
    const container = document.getElementById("cy-explored-labels")
    if (!container) return
    container.innerHTML = ""
    // All entries except the last are previous centers — render as back buttons.
    // The last entry is the current center — render as a plain (non-clickable) label.
    this._exploredNodes.forEach((id, idx) => {
      const node = this.cy && this.cy.getElementById(id)
      const label = (node && node.length) ? (node.data("label") || id) : id
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

  _applyFocusMode(neighborhoods) {
    const centerIds = new Set(neighborhoods.map(h => h.center_id))
    const allHoodIds = new Set()
    neighborhoods.forEach(h => {
      allHoodIds.add(h.center_id)
      h.ids.forEach(id => allHoodIds.add(id))
    })

    // Dim everything outside focus neighborhoods
    this.cy.nodes().forEach(n => {
      n.style({opacity: allHoodIds.has(n.id()) ? 1 : 0.08})
    })
    this.cy.edges().forEach(e => {
      const inHood = allHoodIds.has(e.source().id()) && allHoodIds.has(e.target().id())
      e.style({opacity: inHood ? 1 : 0.05})
    })

    // Highlight center nodes in violet to distinguish them
    centerIds.forEach(id => {
      const n = this.cy.getElementById(id)
      if (n.length) {
        n.style({"background-color": "#8b5cf6", "border-color": "#8b5cf6", "border-width": 3})
      }
    })

    // Fit view to the focus area
    const hoodEles = this.cy.elements().filter(ele => {
      if (ele.isNode()) return allHoodIds.has(ele.id())
      return allHoodIds.has(ele.source().id()) && allHoodIds.has(ele.target().id())
    })
    if (hoodEles.length) this.cy.fit(hoodEles, 120)
  },

  initCy(data) {
    const colors = resolveColors()
    this.cy = cytoscape({
      container: this._cyContainer,
      elements: [...data.nodes, ...data.edges],
      style: cytoscapeStyle(colors),
      layout: {name: "preset"},
      minZoom: 0.05,
      maxZoom: 3,
    })

    // Delay layout until after the browser has painted and the container has
    // its real dimensions (the canvas can start at height 0 during LiveView mount).
    const nodeCount = this.cy.nodes().length
    const msg = document.getElementById("cy-loading-msg")
    if (msg && nodeCount > 0) msg.textContent = `Laying out ${nodeCount} nodes…`
    setTimeout(() => {
      this.cy.resize()
      const layout = this.cy.layout(layoutConfig(nodeCount))
      layout.run()
      // Hide overlay when layout finishes, with a hard timeout fallback in case
      // layoutstop never fires (can happen with very large graphs).
      const fallback = setTimeout(() => {
        this._layoutDone = true
        this._applyDegreeFilter()
        this._hideOverlay()
        this._applyPendingOverlay()
      }, 8000)
      this.cy.one("layoutstop", () => {
        clearTimeout(fallback)
        this._layoutDone = true
        this._applyDegreeFilter()
        this._hideOverlay()
        this._applyPendingOverlay()
      })
    }, 50)

    this._resizeObserver = new ResizeObserver(() => this.cy.resize())
    this._resizeObserver.observe(this.el)

    this.cy.on("tap", "node", (evt) => {
      const id = evt.target.id()
      const currentCenter = this._exploredNodes[this._exploredNodes.length - 1]
      // If this is a previous center (not the current one), unwind back to it
      const prevIdx = this._exploredNodes.indexOf(id)
      if (prevIdx !== -1 && id !== currentCenter) {
        this.pushEvent("unwind_to", {id})
      } else {
        this.pushEvent("node_selected", {id})
      }
    })

    this.cy.on("tap", (evt) => {
      if (evt.target === this.cy) {
        this.pushEvent("deselect", {})
      }
    })

    this.cy.on("mouseover", "node", (evt) => {
      const n = evt.target
      const label = n.data("label") || n.id()
      const text = document.getElementById("cy-hover-text")
      if (text) {
        text.textContent = label
        text.style.display = "block"
      }
      n.connectedEdges().forEach(e => {
        const col = edgeTypeColor(e.data("type"))
        e.style({"line-color": col, "target-arrow-color": col, "width": 4, "opacity": 1})
      })
      n.neighborhood("node").forEach(nb => {
        if (nb.id() !== n.id()) nb.style({"border-width": 2, "border-color": "#f59e0b"})
      })
    })

    this.cy.on("mouseout", "node", (evt) => {
      const n = evt.target
      const text = document.getElementById("cy-hover-text")
      if (text) text.style.display = "none"
      n.connectedEdges().removeStyle("line-color target-arrow-color width opacity")
      n.neighborhood("node").removeStyle("border-width border-color")
    })
  },
}

function layoutConfig(nodeCount) {
  // Force-directed layouts (fcose, cose) are O(n²) and unusable beyond ~150 nodes.
  // For large graphs use concentric layout: places high-degree nodes at centre,
  // low-degree at the periphery. O(n log n), finishes in milliseconds.
  if (nodeCount > 150) {
    return {
      name: "concentric",
      animate: false,
      fit: true,
      padding: 60,
      startAngle: 3 / 2 * Math.PI,
      clockwise: true,
      equidistant: false,
      minNodeSpacing: 10,
      concentric: (node) => node.degree(),
      levelWidth: () => 3,
    }
  }
  return {
    name: "fcose",
    animate: false,
    fit: true,
    padding: 120,
    nodeSeparation: 80,
    idealEdgeLength: 120,
    edgeElasticity: 0.45,
    randomize: true,
    quality: "default",
    numIter: nodeCount > 80 ? 1200 : 2500,
    tile: true,
    tilingPaddingVertical: 20,
    tilingPaddingHorizontal: 20,
  }
}

// Read actual computed color values from a real DOM element so Cytoscape
// (which renders to canvas, not CSS) gets concrete hex/rgb values rather
// than unresolvable CSS variable references.
function resolveColors() {
  const el = document.documentElement
  const cs = getComputedStyle(el)
  const resolve = (v) => {
    // daisyUI exposes vars as bare "oklch(...)" or space-separated channels.
    // Wrap in oklch() if it looks like bare channels (e.g. "89.1% 0.02 90").
    const raw = cs.getPropertyValue(v).trim()
    if (!raw) return null
    // Already a full function value
    if (raw.startsWith("oklch") || raw.startsWith("hsl") || raw.startsWith("rgb") || raw.startsWith("#")) return raw
    // Bare channels — wrap
    return `oklch(${raw})`
  }

  return {
    base:      resolve("--b1")  || "#ffffff",
    content:   resolve("--bc")  || "#1f2937",
    primary:   resolve("--p")   || "#6366f1",
    secondary: resolve("--s")   || "#8b5cf6",
    accent:    resolve("--a")   || "#06b6d4",
    neutral:   resolve("--n")   || "#374151",
  }
}

function cytoscapeStyle(c) {
  return [
    {
      selector: "node",
      style: {
        "label": "",
        "width": (ele) => nodeSize(ele),
        "height": (ele) => nodeSize(ele),
        "background-color": (ele) => nodeColor(ele),
        "border-width": (ele) => ele.data("human_validated") ? 2 : 0,
        "border-color": "#ffffff",
      },
    },
    {
      selector: "node:selected",
      style: {
        "label": "",
        "border-width": 4,
        "border-color": "#f59e0b",
        "background-color": "#f59e0b",
        "width": (ele) => nodeSize(ele) + 6,
        "height": (ele) => nodeSize(ele) + 6,
      },
    },
    {
      selector: "node[?contested]",
      style: {
        "border-width": 2,
        "border-color": "#f59e0b",
      },
    },
    {
      selector: "edge",
      style: {
        "label": "",
        "curve-style": "bezier",
        "target-arrow-shape": "triangle",
        "arrow-scale": 0.8,
        "line-style": (ele) => certaintyStyle(ele.data("certainty")),
        "line-color": c.neutral,
        "target-arrow-color": c.neutral,
        "width": (ele) => 0.5 + ele.data("confidence") * 2,
      },
    },
    {
      selector: "edge[?cross_graph]",
      style: {
        "line-color": "#f59e0b",
        "target-arrow-color": "#f59e0b",
        "opacity": 0.8,
      },
    },
    {
      selector: "edge:selected",
      style: {
        "label": "data(type)",
        "font-size": "10px",
        "color": c.content,
        "text-background-color": c.base,
        "text-background-opacity": 0.9,
        "text-background-padding": "2px",
        "line-color": c.primary,
        "target-arrow-color": c.primary,
      },
    },
  ]
}

function certaintyStyle(certainty) {
  if (certainty === "solid")  return "solid"
  if (certainty === "dotted") return "dotted"
  return "dashed"
}

// Assign one of 3 colors to an edge based on its type string.
// Uses a simple hash so any type always maps to the same color,
// and new/unknown types are handled gracefully.
// Colors: sky blue, violet, rose — distinct and readable on both light/dark.
const EDGE_COLORS = ["#38bdf8", "#a78bfa", "#fb7185"]
function edgeTypeColor(type) {
  if (!type) return EDGE_COLORS[0]
  let hash = 0
  for (let i = 0; i < type.length; i++) hash = (hash * 31 + type.charCodeAt(i)) | 0
  return EDGE_COLORS[Math.abs(hash) % EDGE_COLORS.length]
}

// Scale node size by degree (connection count): hub nodes are visually larger.
// Isolated nodes (deg=0) are sized the same as a 2-edge node so they don't
// look like dead pixels. Min ~13px, max ~42px, logarithmic scale.
function nodeSize(ele) {
  const deg = Math.max(ele.degree(), 2)
  const base = 6
  const scale = 6
  return base + Math.log1p(deg) * scale
}

// Color nodes by connectivity:
//   - No edges → red (isolated, possibly orphaned claims)
//   - Has edges → green, bright at high degree fading to dim at low degree
// Uses HSL so the hue stays green (120°) while lightness drops with distance from center.
function nodeColor(ele) {
  const deg = ele.degree()
  if (deg === 0) return "#ef4444"  // red-500

  // Map degree logarithmically to a lightness range: 65% (dim) → 45% (bright)
  // High-degree nodes get a richer, more saturated green.
  const maxDeg = Math.max(ele.cy().nodes().maxDegree(), 1)
  const t = Math.log1p(deg) / Math.log1p(maxDeg)  // 0..1, 1 = most connected
  const lightness = Math.round(75 - t * 45)        // 75% very pale → 30% deep rich green
  const saturation = Math.round(40 + t * 55)       // 40% washed out → 95% vivid
  return `hsl(120, ${saturation}%, ${lightness}%)`
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
  hooks: {...colocatedHooks, CytoscapeGraph, CodeEditorHook, MonacoFix, CopyToClipboard, DegreeSlider},
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

