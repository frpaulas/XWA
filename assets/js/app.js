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
    if (overlay) {
      console.log("[cy] showOverlay")
      overlay.classList.remove("opacity-0", "pointer-events-none")
    }
  },

  _hideOverlay() {
    const overlay = document.getElementById("cy-loading")
    if (overlay) {
      console.log("[cy] hideOverlay")
      overlay.classList.add("opacity-0", "pointer-events-none")
    }
  },

  _applyPendingOverlay() {
    if (!this.cy) return
    if (this._pendingFocus) {
      console.log("[cy] _applyPendingOverlay: focus mode")
      this.cy.elements().unselect()
      this._applyFocusMode(this._pendingFocus)
    } else if (this._pendingNeighborhood) {
      const n = this._pendingNeighborhood
      const hoodSet = new Set(n.ids || [])
      hoodSet.add(n.center_id)
      console.log("[cy] applying neighborhood, center:", n.center_id, "size:", hoodSet.size, "cy nodes:", this.cy.nodes().length)
      this.cy.elements().unselect()
      this._applyNeighborhood(hoodSet)
      const centerNode = this.cy.getElementById(n.center_id)
      console.log("[cy] center node found:", centerNode.length)
      if (centerNode.length) centerNode.select()
    } else {
      console.log("[cy] _applyPendingOverlay: restore full graph")
      // Both cleared — restore full graph view
      this.cy.elements().unselect()
      this.cy.elements().removeStyle("opacity display background-color border-color border-width")
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

    // Run a force-directed layout on just the visible neighborhood nodes.
    // cose is fast at this scale (<100 nodes) and shows connection structure well.
    hoodEles.layout({
      name: "cose",
      animate: false,
      fit: true,
      padding: 60,
      nodeDimensionsIncludeLabels: false,
      // Pin the center node near the middle
      randomize: false,
      componentSpacing: 40,
      nodeRepulsion: () => 4096,
      idealEdgeLength: () => 80,
      edgeElasticity: () => 32,
      gravity: 1.2,
    }).run()

    this.cy.fit(hoodEles, 60)
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
        this._hideOverlay()
        this._applyPendingOverlay()
      }, 8000)
      this.cy.one("layoutstop", () => {
        clearTimeout(fallback)
        this._layoutDone = true
        this._hideOverlay()
        this._applyPendingOverlay()
      })
    }, 50)

    this._resizeObserver = new ResizeObserver(() => this.cy.resize())
    this._resizeObserver.observe(this.el)

    this.cy.on("tap", "node", (evt) => {
      this.pushEvent("node_selected", {id: evt.target.id()})
    })

    this.cy.on("tap", (evt) => {
      if (evt.target === this.cy) {
        this.pushEvent("deselect", {})
      }
    })

    this.cy.on("mouseover", "node", (evt) => {
      const n = evt.target
      const label = n.data("label") || n.id()
      const strip = document.getElementById("cy-hover-label")
      const text = document.getElementById("cy-hover-text")
      if (strip && text) {
        text.textContent = label
        strip.style.display = "flex"
      }
    })

    this.cy.on("mouseout", "node", () => {
      const strip = document.getElementById("cy-hover-label")
      if (strip) strip.style.display = "none"
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
        "background-color": (ele) => layerColor(ele.data("corpus_layer"), c),
        "border-width": (ele) => ele.data("human_validated") ? 2 : 0,
        "border-color": "#22c55e",
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

function layerColor(layer, c) {
  const colors = {
    self_description: c.primary,
    internal_record:  c.secondary,
    external_context: c.accent,
  }
  return colors[layer] || c.neutral
}

function certaintyStyle(certainty) {
  if (certainty === "solid")  return "solid"
  if (certainty === "dotted") return "dotted"
  return "dashed"
}

// Scale node size by degree (connection count): hub nodes are visually larger.
// Min 6px, max 36px, logarithmic so outlier hubs don't dominate.
function nodeSize(ele) {
  const deg = ele.degree()
  const base = 6
  const scale = 6
  return base + Math.log1p(deg) * scale
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
        const icon = this.el.querySelector("[data-copy-icon]")
        const orig = icon ? icon.getAttribute("data-orig-name") : null
        if (icon) {
          icon.setAttribute("data-orig-name", icon.dataset.name || "")
          // Show a brief "copied" cue by swapping opacity
          this.el.style.opacity = "0.4"
          setTimeout(() => { this.el.style.opacity = "" }, 600)
        }
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

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CytoscapeGraph, CodeEditorHook, MonacoFix, CopyToClipboard},
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

