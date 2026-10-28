import SwiftUI

/// Compatibility entry point retained for older navigation references.
/// Advanced Smart pipeline controls now live in Experimental Features.
struct SmartPipelineSettings: View {
    var body: some View {
        ExperimentalFeaturesView()
    }
}
