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
    this.initCy(JSON.parse(this.el.dataset.graph))
  },

  updated() {
    const data = JSON.parse(this.el.dataset.graph)
    if (this.cy) {
      const colors = resolveColors()
      this.cy.setStyle(cytoscapeStyle(colors))
      this.cy.elements().remove()
      this.cy.add(data.nodes)
      this.cy.add(data.edges)
      this.cy.layout(layoutConfig()).run()
    }
  },

  destroyed() {
    if (this.cy) this.cy.destroy()
  },

  initCy(data) {
    const colors = resolveColors()
    this.cy = cytoscape({
      container: this.el,
      elements: [...data.nodes, ...data.edges],
      style: cytoscapeStyle(colors),
      layout: layoutConfig(),
      minZoom: 0.1,
      maxZoom: 0.8,
    })

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
      n.style({
        "label": n.data("label"),
        "text-wrap": "wrap",
        "text-max-width": "200px",
        "font-size": "22px",
        "text-valign": "bottom",
        "text-margin-y": "6px",
        "color": colors.content,
        "text-background-color": "#fefce8",
        "text-background-opacity": 1,
        "text-background-padding": "4px",
        "text-border-width": 1,
        "text-border-color": "#d4c89a",
        "text-border-opacity": 1,
        "z-index": 9999,
      })
    })

    this.cy.on("mouseout", "node", (evt) => {
      const n = evt.target
      if (!n.selected()) {
        n.style({
          "label": "",
          "z-index": 0,
        })
      }
    })
  },
}

function layoutConfig() {
  return {
    name: "fcose",
    animate: true,
    animationDuration: 400,
    fit: true,
    padding: 60,
    // Node separation — minimum distance between node bounding boxes
    nodeSeparation: 80,
    // Edge length in pixels
    idealEdgeLength: 120,
    edgeElasticity: 0.45,
    // Incremental layout from random positions
    randomize: true,
    // Quality: "default" or "proof" (slower but better overlap removal)
    quality: "default",
    numIter: 2500,
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
        "width": (ele) => 12 + ele.data("confidence") * 8,
        "height": (ele) => 12 + ele.data("confidence") * 8,
        "background-color": (ele) => layerColor(ele.data("corpus_layer"), c),
        "border-width": (ele) => ele.data("human_validated") ? 2 : 0,
        "border-color": "#22c55e",
      },
    },
    {
      selector: "node:selected",
      style: {
        "label": "data(label)",
        "text-wrap": "wrap",
        "text-max-width": "200px",
        "font-size": "11px",
        "text-valign": "bottom",
        "text-margin-y": "6px",
        "color": c.content,
        "text-background-color": c.base,
        "text-background-opacity": 0.9,
        "text-background-padding": "3px",
        "border-width": 3,
        "border-color": c.primary,
        "background-color": c.primary,
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
  hooks: {...colocatedHooks, CytoscapeGraph, CodeEditorHook, MonacoFix},
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

