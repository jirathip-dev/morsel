import SwiftUI

// Issue #151 — the paper 'Copy' pill for the MCP endpoint, shared by the
// onboarding connect field (#141) and the Settings MCP endpoint row. ONE
// implementation of the endpoint copy action (through the shared
// OnboardingContent.copyToPasteboard helper), the 'Copied ✓' confirmation
// and its 1.5 s reset, the paper tokens, and the accessibility label.

struct EndpointCopyPill: View {
    let value: String

    @State private var didCopy = false

    var body: some View {
        Button {
            OnboardingContent.copyToPasteboard(value)
            didCopy = true
        } label: {
            Text(didCopy ? "Copied ✓" : "Copy")
                .font(.morselDataMedium)
                .foregroundStyle(Color.morselForest)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.morselSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.morselInkLine, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy MCP endpoint URL")
        .task(id: didCopy) {
            guard didCopy else { return }
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
