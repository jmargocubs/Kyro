#if os(tvOS)
import SwiftUI

/// Visibility controls live with provider settings; underlying catalogs remain untouched.
struct TVLiveTVHiddenManagementView: View {
    @Bindable var service: LiveTVService
    let profileID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var visibility = TVLiveTVVisibilityStore.shared
    @State private var confirmsRestoreAll = false
    @FocusState private var focusedItem: String?

    private var scope: TVLiveTVVisibilityScope? {
        guard let providerID = service.selectedProviderID else { return nil }
        return TVLiveTVVisibilityScope(profileID: profileID ?? "local", providerID: providerID)
    }

    private var hidden: TVLiveTVVisibilitySnapshot { visibility.snapshot(for: scope) }
    private var channels: [TVLiveTVHiddenChannel] {
        hidden.channels.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 22) {
                    Button("Providers", systemImage: "chevron.left") { dismiss() }
                        .buttonStyle(TVKyroChipStyle())
                        .focused($focusedItem, equals: "back")
                    Text("Hidden Channels and Categories")
                        .font(.system(size: 42, weight: .bold))
                    Spacer()
                    Button("Restore All", systemImage: "arrow.uturn.backward") {
                        confirmsRestoreAll = true
                    }
                    .buttonStyle(TVKyroChipStyle())
                    .disabled(channels.isEmpty && hidden.categories.isEmpty)
                }
                Text(service.selectedProvider?.name ?? "No provider selected")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.siloSecondaryText)

                Text("Hidden Categories").font(.system(size: 32, weight: .bold))
                if hidden.categories.isEmpty {
                    Text("No hidden categories").foregroundStyle(Color.siloSecondaryText)
                }
                ForEach(hidden.categories.sorted(), id: \.self) { category in
                    HStack {
                        Text(category).font(.system(size: 25))
                        Spacer()
                        Button("Restore Category", systemImage: "eye") {
                            visibility.restoreCategory(category, in: scope)
                        }
                        .buttonStyle(TVKyroChipStyle())
                        .focused($focusedItem, equals: "category:\(category)")
                    }
                    .padding(20)
                    .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 16))
                }

                Text("Hidden Channels").font(.system(size: 32, weight: .bold))
                if channels.isEmpty {
                    Text("No hidden channels").foregroundStyle(Color.siloSecondaryText)
                }
                ForEach(channels) { channel in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.name).font(.system(size: 25, weight: .semibold))
                            Text(channel.category).font(.system(size: 19))
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        Spacer()
                        Button("Restore Channel", systemImage: "eye") {
                            visibility.restoreChannel(channel.id, in: scope)
                        }
                        .buttonStyle(TVKyroChipStyle())
                        .focused($focusedItem, equals: "channel:\(channel.id)")
                    }
                    .padding(20)
                    .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 48)
        }
        .background(TVKyroAmbientBackdrop())
        .onExitCommand { dismiss() }
        .onAppear { focusedItem = "back" }
        .confirmationDialog("Restore all hidden channels and categories?", isPresented: $confirmsRestoreAll) {
            Button("Restore All") { visibility.restoreAll(in: scope) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All hidden items for this profile and provider will return to browsing, search, Favorites, and TV Guide.")
        }
    }
}

struct TVLiveTVChannelInformationView: View {
    let channel: LiveTVChannel
    let providerName: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Channel Information").font(.system(size: 40, weight: .bold))
            LiveTVChannelLogo(channel: channel, size: CGSize(width: 150, height: 90))
            information("Name", value: channel.name)
            if let providerName { information("Provider", value: providerName) }
            information("Category", value: channel.category)
            if let guideID = channel.guideID, !guideID.isEmpty {
                information("Guide ID", value: guideID)
            }
            if let streamID = channel.streamID {
                information("Provider stream ID", value: String(streamID))
            }
            Button("Close") { dismiss() }.buttonStyle(TVKyroChipStyle())
        }
        .padding(65)
        .frame(minWidth: 850, minHeight: 480, alignment: .topLeading)
        .background(TVKyroAmbientBackdrop())
        .onExitCommand { dismiss() }
    }

    private func information(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(label).foregroundStyle(Color.siloSecondaryText)
            Text(value).lineLimit(2)
        }
        .font(.system(size: 25))
    }
}
#endif
