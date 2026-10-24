import SwiftUI
import UIKit

private struct PlaybackRequest: Identifiable {
    let id = UUID()
    let item: VideoItem
    let queue: [VideoItem]
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var tab: AppTab = .youtube
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var playback: PlaybackRequest?

    var body: some View {
        ZStack {
            AppBackground()

            Group {
                switch tab {
                case .youtube:
                    SourceGroupView(store: store, source: .youtube) {
                        showAdd = true
                    } onPlay: { item in
                        playback = PlaybackRequest(item: item, queue: store.playbackQueue(for: item))
                    } onSettings: {
                        showSettings = true
                    }
                    .transition(.opacity)

                case .telegram:
                    SourceGroupView(store: store, source: .telegram) {
                        showAdd = true
                    } onPlay: { item in
                        playback = PlaybackRequest(item: item, queue: store.playbackQueue(for: item))
                    } onSettings: {
                        showSettings = true
                    }
                    .transition(.opacity)

                case .downloads:
                    DownloadsView(store: store)
                        .transition(.opacity)

                case .trash:
                    TrashView(store: store) { item in
                        playback = PlaybackRequest(item: item, queue: store.playbackQueue(for: item, inTrash: true))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: tab)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomTabBar(
                selection: $tab,
                downloadCount: store.downloadsGroup.count,
                trashCount: store.trash.count
            )
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                ToastBanner(toast: toast)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: store.toast?.id)
        .sheet(isPresented: $showAdd) {
            AddLinkView(store: store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .fullScreenCover(item: $playback) { request in
            PlayerScreen(item: request.item, queue: request.queue, store: store)
        }
        .onOpenURL { url in
            AppLog.info("open url: \(url.absoluteString)")
            store.handleIncomingURL(url)
        }
        .task {
            let env = ProcessInfo.processInfo.environment
            AppLog.info("app task start log=\(AppLog.logPath)")
            TelegramSession.shared.bootstrap()
            if env["SHIYING_TEST_CLONE"] == "1" {
                _ = store.cloneFirstPlayableForTesting()
            }
            if env["SHIYING_TEST_CLEANUP"] == "1" {
                store.cleanupTestArtifacts()
            }
            if env["SHIYING_TEST_RESET_ALL"] == "1" {
                store.removeAllItemsForTesting()
            }
            if env["SHIYING_KEEP_AWAKE"] == "1" {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            if let qualityRaw = env["SHIYING_SET_QUALITY"],
               let quality = DownloadQuality(rawValue: qualityRaw) {
                AppLog.info("set download quality from env: \(quality.rawValue)")
                store.downloadQuality = quality
            }
            if let raw = env["SHIYING_IMPORT_URL"], !raw.isEmpty {
                AppLog.info("import url from env: \(raw)")
                _ = await store.importInput(raw)
            }
            if env["SHIYING_OPEN_FIRST"] == "1",
               let first = (store.playlist + store.trash).first(where: { $0.isPlayable }) {
                AppLog.info("auto open first item: \(first.title) trashed=\(first.isTrashed) source=\(first.source.rawValue)")
                playback = PlaybackRequest(
                    item: first,
                    queue: store.playbackQueue(for: first, inTrash: first.isTrashed)
                )
            }
            if env["SHIYING_OPEN_TRASH"] == "1" {
                AppLog.info("auto open trash tab")
                tab = .trash
            }
            if let tabRaw = env["SHIYING_OPEN_TAB"] {
                switch tabRaw {
                case "telegram":
                    tab = .telegram
                case "downloads":
                    tab = .downloads
                case "trash":
                    tab = .trash
                default:
                    break
                }
                AppLog.info("auto open tab: \(tabRaw)")
            }
            if let pauseDelay = env["SHIYING_AUTO_PAUSE"].flatMap(Double.init) {
                AppLog.info("auto pause downloads in \(pauseDelay)s")
                Task {
                    try? await Task.sleep(for: .seconds(pauseDelay))
                    store.pauseAllDownloads()
                }
            }
            if let resumeDelay = env["SHIYING_AUTO_RESUME"].flatMap(Double.init) {
                AppLog.info("auto resume downloads in \(resumeDelay)s")
                Task {
                    try? await Task.sleep(for: .seconds(resumeDelay))
                    store.resumeAllDownloads()
                }
            }
            if env["SHIYING_OPEN_SETTINGS"] == "1" {
                try? await Task.sleep(for: .milliseconds(350))
                AppLog.info("auto open settings sheet")
                showSettings = true
            }
            if env["SHIYING_OPEN_ADD"] == "1" {
                try? await Task.sleep(for: .milliseconds(350))
                AppLog.info("auto open add sheet")
                showAdd = true
            }
            if env["SHIYING_SKIP_CLIPBOARD"] != "1" {
                try? await Task.sleep(for: .milliseconds(900))
                await store.importFromClipboardIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            AppLog.info("scene phase: \(String(describing: newPhase))")
            if newPhase == .active {
                store.appBecameActive()
                Task {
                    await store.importFromClipboardIfNeeded()
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.amber)
    }
}
