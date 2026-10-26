import SwiftUI

// MARK: - DogPose
/// What the cartoon dog is doing right now.
enum DogPose {
    case idle      // standing, tail wagging, breathing, blinking
    case walking   // legs cycling (parent drives walkPhase)
    case sitting   // hindquarters down, chest up
}

// MARK: - DogView
/// A living cartoon dog, drawn and rigged entirely in SwiftUI.
/// Long snout, droopy ears, tongue out, collar — unmistakably a dog.
/// The parent drives the animation clocks (walkPhase, wagPhase)
/// with a Timer so the dog stays alive across the whole scene.
struct DogView: View {
    var pose: DogPose = .idle
    var walkPhase: Double = 0
    var wagPhase: Double = 0
    var blinking: Bool = false
    var facingRight: Bool = true
    var carryingBall: Bool = false
    var bounce: Double = 0        // 0 = grounded, 1 = full hop
    var spinDegrees: Double = 0

    // Golden-retriever palette.
    private let fur = Color(red: 0.87, green: 0.66, blue: 0.38)
    private let furDark = Color(red: 0.70, green: 0.50, blue: 0.27)
    private let cream = Color(red: 0.97, green: 0.92, blue: 0.80)
    private let dark = Color(red: 0.25, green: 0.16, blue: 0.10)
    private let pink = Color(red: 0.95, green: 0.55, blue: 0.60)
    private let collarRed = Color(red: 0.80, green: 0.20, blue: 0.20)

    private var walking: Bool { pose == .walking }
    private var sitting: Bool { pose == .sitting }

    var body: some View {
        ZStack {
            // Soft ground shadow.
            Ellipse()
                .fill(.black.opacity(0.15))
                .frame(width: 120, height: 14)
                .offset(y: sitting ? 56 : 50)
                .blur(radius: 3)

            if sitting { sittingDog } else { standingDog }
        }
        .scaleEffect(x: facingRight ? 1 : -1, y: 1)
        .rotationEffect(.degrees(spinDegrees))
        .offset(y: -bounce * 34)
    }

    // MARK: Standing (idle / walking) — facing right

    private var standingDog: some View {
        ZStack {
            // Tail — rises UP and wags, the happy-dog signal.
            RoundedRectangle(cornerRadius: 8)
                .fill(fur)
                .frame(width: 16, height: 52)
                .rotationEffect(.degrees(-35 + sin(wagPhase) * (walking ? 28 : 18)), anchor: .bottom)
                .offset(x: -62, y: -38)

            // Back legs (behind body).
            dogLeg(x: -34, phase: 0)
            dogLeg(x: -20, phase: .pi)

            // Body — longer than tall, clearly a dog torso.
            Ellipse()
                .fill(fur)
                .frame(width: 128, height: 58)
                .scaleEffect(y: walking ? 1.0 : 1.0 + sin(wagPhase * 0.5) * 0.02)
                .offset(y: walking ? -abs(sin(walkPhase)) * 4 : 0)

            // Cream chest/belly.
            Ellipse()
                .fill(cream.opacity(0.85))
                .frame(width: 72, height: 26)
                .offset(x: 8, y: 16)

            // Front legs (in front of body).
            dogLeg(x: 34, phase: .pi)
            dogLeg(x: 20, phase: 0)

            // Neck + head group.
            headGroup
                .offset(x: 62, y: -42)
                .offset(y: walking ? -abs(sin(walkPhase + 1)) * 3 : 0)
        }
    }

    // MARK: Sitting — facing right

    private var sittingDog: some View {
        ZStack {
            // Tail curled on the ground, still wagging.
            RoundedRectangle(cornerRadius: 8)
                .fill(fur)
                .frame(width: 16, height: 44)
                .rotationEffect(.degrees(75 + sin(wagPhase) * 16), anchor: .bottom)
                .offset(x: -44, y: 30)

            // Haunch (thigh).
            Ellipse()
                .fill(fur)
                .frame(width: 72, height: 58)
                .offset(x: -26, y: 24)

            // Folded hind paw.
            RoundedRectangle(cornerRadius: 7)
                .fill(furDark)
                .frame(width: 48, height: 16)
                .offset(x: -24, y: 48)

            // Upright chest.
            RoundedRectangle(cornerRadius: 24)
                .fill(fur)
                .frame(width: 62, height: 96)
                .offset(x: 14, y: -8)
                .rotationEffect(.degrees(-6))

            // Cream chest.
            RoundedRectangle(cornerRadius: 14)
                .fill(cream.opacity(0.85))
                .frame(width: 32, height: 60)
                .offset(x: 24, y: -2)

            // Front legs straight down.
            dogLegStatic(x: 8, h: 52)
            dogLegStatic(x: 28, h: 52)

            // Head on top.
            headGroup
                .offset(x: 26, y: -70)
        }
    }

    // MARK: Parts

    /// Animated leg for walking.
    private func dogLeg(x: CGFloat, phase: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(fur)
                .frame(width: 16, height: 40)
            // Paw.
            Ellipse()
                .fill(furDark)
                .frame(width: 20, height: 12)
                .offset(y: 20)
        }
        .rotationEffect(.degrees(walking ? sin(walkPhase + phase) * 30 : 0), anchor: .top)
        .offset(x: x, y: 30)
    }

    /// Static leg (for sitting).
    private func dogLegStatic(x: CGFloat, h: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(fur)
                .frame(width: 16, height: h)
            Ellipse()
                .fill(furDark)
                .frame(width: 20, height: 12)
                .offset(y: h / 2)
        }
        .offset(x: x, y: 30)
    }

    /// Head facing right: long snout, droopy ear, tongue, collar.
    private var headGroup: some View {
        ZStack {
            // Neck.
            RoundedRectangle(cornerRadius: 10)
                .fill(fur)
                .frame(width: 30, height: 36)
                .offset(x: -14, y: 22)
                .rotationEffect(.degrees(15))

            // Collar — the "pet dog" signal.
            RoundedRectangle(cornerRadius: 4)
                .fill(collarRed)
                .frame(width: 34, height: 10)
                .offset(x: -12, y: 14)
                .rotationEffect(.degrees(15))

            // Skull — slightly oval, not a perfect ball.
            Ellipse()
                .fill(fur)
                .frame(width: 54, height: 48)

            // Forehead patch.
            Ellipse()
                .fill(cream.opacity(0.5))
                .frame(width: 30, height: 20)
                .offset(x: -6, y: -14)

            // LONG snout — the anti-bear feature. Juts out to the right.
            RoundedRectangle(cornerRadius: 12)
                .fill(cream)
                .frame(width: 44, height: 26)
                .offset(x: 30, y: 8)

            // Nose — big, at the very tip of the snout.
            Ellipse()
                .fill(dark)
                .frame(width: 16, height: 13)
                .offset(x: 50, y: 4)

            // Nostrils.
            Circle().fill(.black.opacity(0.5)).frame(width: 3, height: 3).offset(x: 47, y: 3)
            Circle().fill(.black.opacity(0.5)).frame(width: 3, height: 3).offset(x: 53, y: 3)

            // Mouth line under the snout.
            Path { p in
                p.move(to: CGPoint(x: 18, y: 20))
                p.addQuadCurve(to: CGPoint(x: 44, y: 18),
                              control: CGPoint(x: 31, y: 26))
            }
            .stroke(dark, lineWidth: 2.5)

            // Tongue — hanging out, the universal dog signal.
            RoundedRectangle(cornerRadius: 6)
                .fill(pink)
                .frame(width: 14, height: 24)
                .offset(x: 30, y: 30)
                .rotationEffect(.degrees(8 + sin(wagPhase * 0.8) * 6))

            // Eye — friendly, with a highlight.
            ZStack {
                Circle().fill(dark).frame(width: 11, height: 11)
                Circle().fill(.white).frame(width: 3.5, height: 3.5).offset(x: -2, y: -2)
            }
            .scaleEffect(y: blinking ? 0.12 : 1.0)
            .offset(x: 6, y: -8)

            // DROOPY ear — hangs DOWN the side of the head like a
            // lab/golden, never a round nub on top.
            RoundedRectangle(cornerRadius: 10)
                .fill(furDark)
                .frame(width: 22, height: 46)
                .rotationEffect(.degrees(12 + sin(wagPhase * 0.7) * 5), anchor: .top)
                .offset(x: -18, y: -8)

            // Ball in mouth when fetching.
            if carryingBall {
                Circle()
                    .fill(.green)
                    .frame(width: 18, height: 18)
                    .offset(x: 38, y: 26)
            }
        }
    }
}
