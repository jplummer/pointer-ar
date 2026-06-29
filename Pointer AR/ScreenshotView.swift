#if DEBUG
import SwiftUI

struct ScreenshotView: View {
    let config: ScreenshotConfig
    @StateObject private var session: AimSession

    init(config: ScreenshotConfig) {
        self.config = config
        UserDefaults.standard.set(
            config.targetPickableId,
            forKey: "pointer.lastSelectedTarget"
        )
        _session = StateObject(wrappedValue: AimSession())
    }

    var body: some View {
        // ZStack is the full-screen canvas: photo → 3D overlay → optional dim.
        // UI chrome (picker header, az/el) is added via safeAreaInset so it
        // renders in a separate layer guaranteed to be above SceneKit's Metal
        // rendering, which can bleed above SwiftUI ZStack siblings.
        ZStack {
            if let path = Bundle.main.path(forResource: config.backgroundImage, ofType: "jpg"),
               let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                Color.indigo.ignoresSafeArea()
            }

            ScreenshotArrowView(config: config)
                .ignoresSafeArea()

            // Dim for picker shot so list text stays legible over the scene.
            // Stacked on top of SceneKit, not in place of it, so disc and arrow
            // remain visible through the open picker (matching the real app).
            if config.showPicker {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
            }
        }
        // Picker header — safeAreaInset renders above all ZStack layers
        .safeAreaInset(edge: .top, spacing: 0) {
            Group {
                if config.showPicker {
                    TargetPickerExpando(session: session)
                } else {
                    staticPickerHeader
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
        }
        // Az/El readout — same treatment at the bottom
        .safeAreaInset(edge: .bottom, spacing: 0) {
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
