#if DEBUG
import SwiftUI

struct ScreenshotView: View {
    let config: ScreenshotConfig
    @StateObject private var session = AimSession()

    var body: some View {
        ZStack {
            // Background: raw JPEG from bundle (not an asset catalog entry)
            if let path = Bundle.main.path(forResource: config.backgroundImage, ofType: "jpg"),
               let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
            } else {
                // Fallback: visible so a missing filename is obvious during iteration
                Color.indigo.ignoresSafeArea()
            }

            ScreenshotArrowView(config: config)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Target picker — collapsed (shows target name) or expanded for picker shot
                TargetPickerExpando(session: session)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

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
        }
        .onAppear {
            // Select the correct target so the picker header shows the right name
            if let t = session.celestialCatalog.first(where: { $0.displayName == config.targetName }) {
                session.aimMode = .celestial(t)
            } else if let t = session.groundCatalog.first(where: { $0.displayName == config.targetName }) {
                session.aimMode = .ground(t)
            }
            if config.showPicker {
                session.pickerExpanded = true
            }
        }
    }
}

#Preview {
    ScreenshotView(config: ScreenshotConfig.configs[0])
}
#endif
