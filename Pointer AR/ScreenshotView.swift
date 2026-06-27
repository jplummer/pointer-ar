#if DEBUG
import SwiftUI

struct ScreenshotView: View {
    let config: ScreenshotConfig
    @StateObject private var session: AimSession

    init(config: ScreenshotConfig) {
        self.config = config
        // Pre-seed UserDefaults so AimSession starts with the correct target on
        // its very first render — avoids a one-frame flash of the default (Sun)
        // and eliminates the onAppear timing race across sequential UITest runs.
        UserDefaults.standard.set(
            config.targetPickableId,
            forKey: "pointer.lastSelectedTarget"
        )
        _session = StateObject(wrappedValue: AimSession())
    }

    var body: some View {
        // VStack drives the layout so SwiftUI applies safe-area insets correctly.
        // Photo and overlays go in .background modifiers rather than as ZStack
        // siblings — that way they extend edge-to-edge without confusing the
        // safe-area framing on Dynamic Island devices.
        VStack(spacing: 0) {
            if config.showPicker {
                // Live picker for the picker shot — session is pre-seeded via
                // UserDefaults in init() so the first render shows the right target.
                TargetPickerExpando(session: session)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            } else {
                // Static closed-picker header built directly from config.targetName.
                // Avoids AimSession / TargetPickerExpando timing races across
                // sequential UITest app launches.
                staticPickerHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)

            // Az/El readout — same styling as ContentView.azimuthElevationReadout
            HStack(spacing: 18) {
                Text("Az \(String(format: "%.0f°", config.azimuthDeg))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("El \(String(format: "%+.0f°", config.elevationDeg))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.52))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 3D compass + arrow (behind VStack content)
        .background {
            if config.showPicker {
                // Picker shot: dim the photo so white picker text reads clearly
                Color.black.opacity(0.30).ignoresSafeArea()
            } else {
                ScreenshotArrowView(config: config).ignoresSafeArea()
            }
        }
        // Background photo (furthest back)
        .background {
            if let path = Bundle.main.path(forResource: config.backgroundImage, ofType: "jpg"),
               let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color.indigo.ignoresSafeArea()
            }
        }
        .onAppear {
            if config.showPicker {
                session.pickerExpanded = true
            }
        }
    }

    private var staticPickerHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pointing at")
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.92))
                Text(config.targetName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.white.opacity(0.88))
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
    }
}

#Preview {
    ScreenshotView(config: ScreenshotConfig.configs[0])
}
#endif
