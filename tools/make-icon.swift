// Erzeugt Resources/AppIcon.icon – ein Icon-Composer-Icon (macOS 26/27, Liquid Glass).
// Aus diesem Format rendert macOS selbst alle Varianten: Hell, Dunkel, Klar und Getönt –
// das Icon wechselt also automatisch mit dem Erscheinungsbild. Glas, Glanzlicht, Schatten und die
// Squircle-Maske kommen vom System, deshalb sind die Ebenen hier bewusst flach (Apple-Vorgabe).
// Kompiliert wird es zu Assets.car + AppIcon.icns per actool – das gibt es nur mit Xcode, deshalb
// über GitHub Actions: tools/fetch-icon.sh.
// Aufruf: swift tools/make-icon.swift
import AppKit

// ShareMount: Laufwerk vorn, Netzleitung dahinter
let tint = (r: 0.16, g: 0.47, b: 0.98)          // Grundfarbe, daraus macht macOS den Verlauf
let darkTint = (r: 0.05, g: 0.10, b: 0.20)
let glyphDark = (r: 0.40, g: 0.66, b: 1.00)     // Symbolfarbe im Dunkelmodus

let canvas: CGFloat = 1024
let out = URL(fileURLWithPath: "Resources/AppIcon.icon")

func layer(_ name: String, draw: (CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSColor.white.setStroke()
    draw(canvas)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: out.appendingPathComponent("Assets/\(name).png"))
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, centerY: CGFloat) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [.white]))
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let sz = img.size
    img.draw(in: NSRect(x: (canvas - sz.width) / 2, y: centerY - sz.height / 2, width: sz.width, height: sz.height))
}

func color(_ c: (r: Double, g: Double, b: Double)) -> String {
    String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.r, c.g, c.b)
}

try? FileManager.default.removeItem(at: out)
try! FileManager.default.createDirectory(at: out.appendingPathComponent("Assets"), withIntermediateDirectories: true)

// Hinten: Netzleitung (Stich nach unten + waagerechte Schiene)
layer("Netz") { s in
    NSBezierPath(roundedRect: NSRect(x: s / 2 - 30, y: 250, width: 60, height: 190), xRadius: 30, yRadius: 30).fill()
    NSBezierPath(roundedRect: NSRect(x: 212, y: 220, width: 600, height: 60), xRadius: 30, yRadius: 30).fill()
    NSBezierPath(ovalIn: NSRect(x: s / 2 - 66, y: 184, width: 132, height: 132)).fill()
}
// Vorn: Laufwerk
layer("Laufwerk") { s in
    symbol("externaldrive.fill", size: 400, weight: .semibold, centerY: 600)
}

let json = """
{
  "fill-specializations" : [
    { "value" : { "automatic-gradient" : "\(color(tint))" } },
    { "appearance" : "dark", "value" : { "automatic-gradient" : "\(color(darkTint))" } }
  ],
  "groups" : [
    {
      "layers" : [
        {
          "fill-specializations" : [
            { "value" : { "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" } },
            { "appearance" : "dark", "value" : { "solid" : "\(color(glyphDark))" } }
          ],
          "glass" : true,
          "image-name" : "Laufwerk.png",
          "name" : "Laufwerk"
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.2 }
    },
    {
      "layers" : [
        {
          "fill-specializations" : [
            { "value" : { "solid" : "srgb:1.00000,1.00000,1.00000,1.00000" } },
            { "appearance" : "dark", "value" : { "solid" : "\(color(glyphDark))" } }
          ],
          "glass" : true,
          "image-name" : "Netz.png",
          "name" : "Netz",
          "opacity" : 0.75
        }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : [ "macOS" ] }
}
"""
try! json.write(to: out.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Geschrieben: \(out.path) – jetzt tools/fetch-icon.sh")
