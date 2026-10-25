import SwiftUI

/// Things to play on the TV: your photos and videos, YouTube, any link, or the whole screen.
struct PlayTab: View {
    enum Mode: String, CaseIterable {
        case photos = "Photos", youtube = "YouTube", link = "Link", mirror = "Mirror"
    }

    @AppStorage("playMode") private var mode: Mode = .photos
    @State private var page = WebPageState()
    /// Shared with the menu inside the photo viewer.
    @AppStorage("castAutoShow") private var autoShow = true

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .photos: PhotosPane()
                case .youtube: YouTubePage(page: page)
                case .link: LinkForm()
                case .mirror: MirrorPane()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Play", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                DevicePicker()
                if mode == .photos {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Toggle("Show on TV Automatically", isOn: $autoShow)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                if mode == .youtube {
                    ToolbarItemGroup(placement: .navigationBarLeading) {
                        Button("Back", systemImage: "chevron.left") { page.goBack() }.disabled(!page.canGoBack)
                        Button("Forward", systemImage: "chevron.right") { page.goForward() }.disabled(!page.canGoForward)
                    }
                }
            }
        }
    }
}
