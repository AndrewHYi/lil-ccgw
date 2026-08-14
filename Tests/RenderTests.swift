import AppKit
import CryptoKit
import Foundation
import SwiftUI

/// Tests that render the real views and measure the result.
///
/// These are possible because SwiftUI hosts fine inside this plain `swiftc`
/// binary — `NSHostingView.fittingSize` returns real layout geometry and
/// `ImageRenderer` rasterises, with no bundle identifier and no host app. So
/// menu bar geometry can be asserted rather than estimated, which matters for a
/// surface whose whole job is to occupy a few contested points of screen.
///
/// The measurements here caught two things logic tests could not: four tiers
/// that changed width between animation frames (shoving neighbouring menu bar
/// icons sideways several times a second), and three documented widths that were
/// simply wrong.
@MainActor
func runRenderTests() {
    /// Laid-out size of a view, as the menu bar would size it.
    func size<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layout()
        return host.fittingSize
    }

    func label(
        mode: TitleMode = .iconOnly, tier: SkitTier? = .ok,
        frame: Int = 0, heat: BudgetHeat = .normal, budget: Budget? = nil
    ) -> MenuBarLabel {
        let (snap, sample) = MenuBarLabel.sampleSnapshot()
        return MenuBarLabel(
            snapshot: snap, scene: SkitScene.scene(for: tier), heat: heat,
            frame: frame, mode: mode, trackedBudget: budget ?? sample
        )
    }

    T.suite("title mode widths") {
        // Pinned to measured values. A tolerance absorbs font-metric drift
        // between OS versions while still failing on a real layout change.
        let expected: [(TitleMode, Double)] = [
            (.spendOfLimit, 108),   // "$9.34/$75 5h"
            (.iconAndSpend, 61),    // "$9.34"
            (.iconOnly, 20),        // glyph alone, fixed slot
            (.iconAndPace, 61),     // "0.32×"
            (.statusline, 215),     // "$9.34/$75 5h │ $23/$1200 30d"
        ]
        for (mode, want) in expected {
            let w = size(label(mode: mode)).width
            T.expect(abs(w - want) <= 8,
                     "\(mode.rawValue) renders ~\(Int(want))pt (got \(Int(w)))")
        }

        // Ordering is the durable claim: icon-only must stay the narrowest and
        // statusline the widest, whatever the exact metrics.
        let widths = Dictionary(uniqueKeysWithValues: TitleMode.allCases.map {
            ($0, size(label(mode: $0)).width)
        })
        T.expect(widths[.iconOnly]! < widths[.iconAndSpend]!, "icon-only is narrowest")
        T.expect(widths[.statusline]! > widths[.spendOfLimit]!, "statusline is widest")
        T.expect(widths[.statusline]! > 150, "statusline is genuinely wide — not the default for a reason")
    }

    T.suite("animation frames do not resize the item") {
        // THE REGRESSION TEST. Before the fixed-width glyph slot, crit varied
        // 13→16pt, melt 15→13, payday 20→14, zen 18→13 — so the status item
        // resized on every animation tick and shoved its neighbours around.
        // Measured, not assumed: this failed before the fix and passes after.
        for tier in SkitTier.allCases {
            let scene = SkitScene.scene(for: tier)
            let widths = (0..<scene.frames.count).map {
                size(label(tier: tier, frame: $0)).width
            }
            let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
            T.expect(spread < 0.5,
                     "\(tier.rawValue) frames render the same width (spread \(spread)pt)")
        }

        // Same requirement in a text mode: swapping the glyph must not move the
        // digits either.
        for tier in SkitTier.allCases {
            let scene = SkitScene.scene(for: tier)
            let widths = (0..<scene.frames.count).map {
                size(label(mode: .spendOfLimit, tier: tier, frame: $0)).width
            }
            let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
            T.expect(spread < 0.5, "\(tier.rawValue) with text is width-stable")
        }
    }

    T.suite("animation frames do not move the glyph inside its slot") {
        // The slot pins the *layout* width, which is what stops the status item
        // resizing — the suite above proves it still does. It does nothing about
        // the glyph sliding around inside that slot: centred in 20pt, a 13pt
        // symbol sits 3.5pt from the left edge and a 16pt one sits 2pt, so the
        // icon jumps sideways on every tick while the item itself holds still.
        //
        // Measured before the fix: crit and zen moved 4px, payday 6px, melt 2px.
        // Layout-width assertions cannot see any of it, which is why this
        // measures ink — the leftmost and rightmost columns that actually get
        // drawn.
        func ink<V: View>(_ view: V) -> (lo: Int, hi: Int)? {
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(x: 0, y: 0, width: 60, height: 24)
            host.layout()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            var lo = Int.max, hi = -1
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    lo = min(lo, x); hi = max(hi, x); break
                }
            }
            return hi < 0 ? nil : (lo, hi)
        }

        for tier in SkitTier.allCases {
            let scene = SkitScene.scene(for: tier)
            guard scene.frames.count > 1 else { continue }
            let extents = (0..<scene.frames.count).compactMap {
                ink(label(mode: .iconOnly, tier: tier, frame: $0))
            }
            guard extents.count == scene.frames.count else {
                T.fail("\(tier.rawValue): not every frame rasterised")
                continue
            }
            let lefts = extents.map(\.lo), rights = extents.map(\.hi)

            // The left edge is the anchor the eye tracks, and it must be exact.
            T.equal(lefts.max()! - lefts.min()!, 0,
                    "\(tier.rawValue) glyph's left edge holds still across frames")

            // The right edge gets 1px (0.5pt at 2×), because that is the floor
            // SF Symbols actually offers rather than a number chosen to pass:
            // `moon.zzz` against `moon.zzz.fill` — a canonical outline/fill pair
            // of identical natural width — still differs by 1px where the fill
            // antialiases. That is the shape changing, which is the animation
            // working. Anything larger is the glyph being re-centred.
            T.expect(rights.max()! - rights.min()! <= 1,
                     "\(tier.rawValue) glyph's right edge moves at most 1px (\(rights.max()! - rights.min()!))")
        }
    }

    T.suite("a tier's frames share one natural width") {
        // The mechanism behind the suite above, asserted directly because it is
        // the thing to preserve when picking symbols: frames drawn from a single
        // family (thermometer.medium/high, flame/flame.fill) match automatically,
        // and two unrelated symbols almost never do. Getting this right is what
        // makes the ink line up; the ink test is what proves it did.
        for tier in SkitTier.allCases {
            let widths = SkitScene.scene(for: tier).frames.map { size(Image(systemName: $0)).width }
            T.equal(Set(widths).count, 1,
                    "\(tier.rawValue) frames all measure the same (\(widths))")
        }
    }

    T.suite("no two states share a silhouette") {
        // The bitmap-hash test proves two tiers are not byte-identical. It says
        // nothing about being *confusable*, and that is the property that
        // matters in a monochrome 20pt slot.
        //
        // Caught a real near-miss: pairing melt's frames as
        // `figure.run.circle`/`.fill` — the only same-width runner pair, since
        // `figure.*` has no fill variant — put it at 0.85 overlap with
        // `pause.circle.fill`. Runaway spend and paused enforcement are the two
        // states it is worst to mistake for each other.
        func mask(_ symbol: String) -> [Bool] {
            let host = NSHostingView(
                rootView: Image(systemName: symbol)
                    .frame(width: MenuBarLabel.glyphSlotWidth, alignment: .center))
            host.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
            host.layout()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [] }
            host.cacheDisplay(in: host.bounds, to: rep)
            var m: [Bool] = []
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    m.append((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.35)
                }
            }
            return m
        }

        // Grouped by state: frames *within* a tier are meant to look alike — that
        // is the animation — so only cross-state pairs are compared.
        var groups: [(String, [String])] = SkitTier.allCases.map {
            ($0.rawValue, SkitScene.scene(for: $0).frames)
        }
        groups.append(("unreachable", ["wifi.slash"]))
        groups.append(("paused", ["pause.circle.fill"]))
        groups.append(("no-data", ["circle.dotted"]))

        var masks: [String: [Bool]] = [:]
        for (_, symbols) in groups { for s in symbols where masks[s] == nil { masks[s] = mask(s) } }

        // 0.6 sits above the widest legitimate overlap the ladder already
        // carries (leaf.fill against flame.fill, 0.43) and well below the 0.85
        // that would have shipped.
        for i in groups.indices {
            for j in groups.indices where j > i {
                for a in groups[i].1 {
                    for b in groups[j].1 {
                        guard let ma = masks[a], let mb = masks[b],
                              ma.count == mb.count, !ma.isEmpty else {
                            T.fail("could not compare \(a) with \(b)")
                            continue
                        }
                        var inter = 0, union = 0
                        for k in ma.indices {
                            if ma[k] && mb[k] { inter += 1 }
                            if ma[k] || mb[k] { union += 1 }
                        }
                        let iou = union == 0 ? 1.0 : Double(inter) / Double(union)
                        T.expect(iou < 0.6, String(format:
                            "%@ (%@) and %@ (%@) are distinguishable — overlap %.2f",
                            a, groups[i].0, b, groups[j].0, iou))
                    }
                }
            }
        }
    }

    T.suite("no glyph is clipped by the slot") {
        // The slot is 20pt because party.popper.fill measures exactly 20 and
        // figure.mind.and.body 18; a 16pt slot clipped both. Any new glyph wider
        // than the slot would be silently cropped, so assert the invariant
        // rather than trusting the choice to survive edits.
        var widest = 0.0
        var offender = ""
        for tier in SkitTier.allCases {
            for symbol in SkitScene.scene(for: tier).frames {
                let w = size(Image(systemName: symbol)).width
                if w > widest { widest = w; offender = symbol }
            }
        }
        for symbol in ["wifi.slash", "pause.circle.fill", "circle.dotted"] {
            let w = size(Image(systemName: symbol)).width
            if w > widest { widest = w; offender = symbol }
        }
        T.expect(widest <= MenuBarLabel.glyphSlotWidth,
                 "widest glyph \(offender) at \(widest)pt fits the \(MenuBarLabel.glyphSlotWidth)pt slot")
    }

    T.suite("width growth with spend is bounded") {
        // monospacedDigit equalises digit *glyphs*, not string *length*: the
        // item still grows as the number gains characters. That's acceptable,
        // but it must not be able to grow without limit, or the menu bar item
        // starts evicting its neighbours.
        @MainActor func widthForSpend(_ spend: Double, limit: Double) -> Double {
            let json = """
            {"id":"session","scope":"global","window":"5h",
             "effective_limit_usd":\(limit),"spent_usd":\(spend),"remaining_usd":1,
             "pct":50,"action":"block","exhausted":false,"soft":false,
             "burn_rate_hr":null,"sustainable_hr":null,"pace":null,
             "bump_usd":null,"bump_expires_at":null}
            """
            let b = try! decodeFixture(Budget.self, json)
            return size(label(mode: .spendOfLimit, budget: b)).width
        }
        let small = widthForSpend(9.34, limit: 75)
        let large = widthForSpend(999.99, limit: 1200)
        T.expect(large >= small, "a longer number is not narrower")
        T.expect(large - small < 60, "growth from $9.34 to $999.99 stays under 60pt (got \(large - small))")

        // Equal-length values must render identically — this is what
        // monospacedDigit actually buys, and it stops the item twitching while
        // spend ticks up within the same digit count.
        T.close(widthForSpend(11.11, limit: 75), widthForSpend(88.88, limit: 75),
                "equal-length values render the same width", tolerance: 0.5)
    }

    T.suite("every state renders something visible") {
        // A mistyped SF Symbol name renders as nothing at all, which would ship
        // an invisible menu bar item — the app would look dead while working.
        for tier in SkitTier.allCases {
            for frame in 0..<SkitScene.scene(for: tier).frames.count {
                let s = size(label(tier: tier, frame: frame))
                T.expect(s.width > 8 && s.height > 8,
                         "\(tier.rawValue) frame \(frame) has a visible size (\(s.width)x\(s.height))")
            }
        }
        for scene in [SkitScene.scene(for: nil)] {
            let l = MenuBarLabel(snapshot: GatewaySnapshot(), scene: scene, heat: .normal,
                                 frame: 0, mode: .iconOnly, trackedBudget: nil)
            T.expect(size(l).width > 8, "the no-data state is visible too")
        }
    }

    T.suite("tiers are visually distinct, not just differently named") {
        // The existing symbol-name test would pass even if two names happened to
        // render identical art. Hashing the rasterised output is the stronger
        // claim, and it is what the escalation actually depends on.
        var hashes: [String: SkitTier] = [:]
        for tier in SkitTier.allCases {
            let renderer = ImageRenderer(content: label(tier: tier).frame(width: 24, height: 20))
            renderer.scale = 2
            guard let data = renderer.nsImage?.tiffRepresentation else {
                T.expect(false, "\(tier.rawValue) rasterised")
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let clash = hashes[digest] {
                T.expect(false, "\(tier.rawValue) renders identically to \(clash.rawValue)")
            }
            hashes[digest] = tier
        }
        T.equal(hashes.count, SkitTier.allCases.count,
                "\(SkitTier.allCases.count) tiers produce \(SkitTier.allCases.count) distinct bitmaps")
    }

    T.suite("budget heat changes the rendering") {
        // Colour is the second axis; if heat stopped affecting the output, the
        // soft-threshold warning would vanish silently while tests still passed.
        var hashes = Set<String>()
        for heat in [BudgetHeat.normal, .soft, .exhausted] {
            let renderer = ImageRenderer(content: label(heat: heat).frame(width: 24, height: 20))
            renderer.scale = 2
            if let data = renderer.nsImage?.tiffRepresentation {
                hashes.insert(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            }
        }
        T.equal(hashes.count, 3, "normal, soft and exhausted render differently")
    }
}
