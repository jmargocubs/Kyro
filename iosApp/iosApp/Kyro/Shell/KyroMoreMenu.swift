import SwiftUI

/// A secondary Silo root exposed from Kyro's shared application header.
/// Actions push a distinct Route; they never mutate global tab selection.
struct KyroMoreMenuItem: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let action: () -> Void
}

struct KyroMoreMenuContext {
    let items: [KyroMoreMenuItem]
}

extension EnvironmentValues {
    @Entry var kyroMoreMenu: KyroMoreMenuContext? = nil
}

/// An adaptive, non-persistent menu control. It vanishes outside an
/// authenticated shell that supplied supported secondary destinations.
struct KyroMoreMenuButton: View {
    @Environment(\.kyroMoreMenu) private var context

    var body: some View {
        if let context, !context.items.isEmpty {
            Menu {
                ForEach(context.items) { item in
                    Button(action: item.action) {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface)
                    .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More destinations")
            .accessibilityIdentifier("kyroMoreMenu")
        }
    }
}
