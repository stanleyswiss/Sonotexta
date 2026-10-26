import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                UpdatesView()
                StatsSettingsView()
                PrivacySettingsView()
                SupportView()
            }
        }
    }
}
