.pragma library

// Pure helpers for the decade workspace widget, kept free of QML so they can
// be tested with plain node (tests/run.js).
//
// workspace-map.sh owns the data: ~/.local/state/hypr/workspace-map-slots maps
// a slot index to the monitor description that owns that decade
// ("1<TAB>AOC Q27G3G3R3 QOWP3JA001548" = workspaces 11-20), and
// ~/.local/state/hypr/workspace-map-mode holds the mode (missing = decade).

var DEFAULT_DECADE_SIZE = 10

// "0\tDesc A\n1\tDesc B\n" -> { 0: "Desc A", 1: "Desc B" }. Malformed lines are skipped.
function parseSlots(text) {
  var slots = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var tab = line.indexOf("\t")
    if (tab <= 0) continue
    var index = Number(line.slice(0, tab))
    var owner = line.slice(tab + 1).replace(/^\s+|\s+$/g, "")
    if (!isFinite(index) || index < 0 || Math.floor(index) !== index || owner.length === 0) continue
    slots[index] = owner.slice(0, 200)
  }
  return slots
}

function parseMode(text) {
  var mode = String(text || "").replace(/^\s+|\s+$/g, "")
  return mode.length > 0 ? mode : "decade"
}

function slotIndex(id, decadeSize) {
  var size = decadeSize > 0 ? decadeSize : DEFAULT_DECADE_SIZE
  return Math.floor((id - 1) / size)
}

// Where workspace `id` sits relative to its owner.
//   hostDescription        description of the monitor showing it now
//   connectedDescriptions  descriptions of every connected monitor
// Returns { displaced, owner, ownerConnected }. Only decade mode has owners;
// split modes and workspaces outside the slot table are never displaced.
function placement(id, hostDescription, slots, mode, connectedDescriptions, decadeSize) {
  var result = { displaced: false, owner: "", ownerConnected: false }
  if (parseMode(mode) !== "decade" || !(id > 0) || !slots) return result
  var owner = slots[slotIndex(id, decadeSize)]
  if (!owner) return result
  result.owner = owner
  var connected = connectedDescriptions || []
  for (var i = 0; i < connected.length; i++) {
    if (connected[i] === owner) { result.ownerConnected = true; break }
  }
  result.displaced = !!hostDescription && hostDescription !== owner
  return result
}

// Digit-row label: position within the decade (11 -> 1, 20 -> 0). A borrowed
// workspace shows its full number, since its position digit would repeat one
// of the host display's own.
function label(id, displaced, decadeSize) {
  if (displaced) return String(id)
  var size = decadeSize > 0 ? decadeSize : DEFAULT_DECADE_SIZE
  var digit = id % size
  return String(digit === 0 && size === 10 ? 0 : digit)
}
