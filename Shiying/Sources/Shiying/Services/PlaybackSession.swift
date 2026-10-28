import SwiftUI
import UIKit

@MainActor
final class PlaybackSession: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let item: VideoItem
        let queue: [VideoItem]
    }

    let model = PlayerViewModel()

    @Published private(set) var request: Request?
    @Published private(set) var currentItem: VideoItem?
    @Published private(set) var isMinimized = false
    private static let savedItemKey = "shiying.playback.savedItem"

    func start(item: VideoItem, queue: [VideoItem]) {
        guard !item.isTrashed, item.isPlayable else { return }
        request = Request(item: item, queue: queue.filter { $0.source == item.source && !$0.isTrashed && $0.isPlayable })
        currentItem = item
        UserDefaults.standard.set(item.id.uuidString, forKey: Self.savedItemKey)
        isMinimized = false
        OrientationController.shared.allowRotation()
    }

    func startNext(item: VideoItem, queue: [VideoItem]) {
        let wasMinimized = isMinimized
        start(item: item, queue: queue)
        if wasMinimized {
            minimize()
        }
    }

    func updateCurrentItem(_ item: VideoItem) {
        currentItem = item
        model.invalidatePendingLoad()
    }

    func minimize() {
        guard request != nil else { return }
        isMinimized = true
        OrientationController.shared.lockPortrait()
    }

    func expand() {
        guard request != nil else { return }
        isMinimized = false
        OrientationController.shared.allowRotation()
    }

    func playNext(using store: AppStore) {
        guard let request, let currentItem,
              let index = request.queue.firstIndex(where: { $0.id == currentItem.id }),
              index + 1 < request.queue.count else { return }
        let next = request.queue[index + 1]
        store.movePlayedToTrash(itemID: currentItem.id)
        startNext(item: next, queue: request.queue)
    }

    func close() {
        guard request != nil else { return }
        request = nil
        currentItem = nil
        UserDefaults.standard.removeObject(forKey: Self.savedItemKey)
        isMinimized = false
        model.stop()
        OrientationController.shared.lockPortrait()
    }
}

@MainActor
final class OrientationController {
    static let shared = OrientationController()

    private(set) var mask: UIInterfaceOrientationMask = .portrait

    func allowRotation() {
        mask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    func lockPortrait() {
        guard UIDevice.current.userInterfaceIdiom != .pad else {
            mask = .all
            return
        }
        mask = .portrait
        request(.portrait)
    }

    func toggle() {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        guard let scene = activeScene else { return }
        if scene.effectiveGeometry.interfaceOrientation.isLandscape {
            mask = .portrait
            request(.portrait, in: scene)
        } else {
            mask = .allButUpsideDown
            request(.landscapeRight, in: scene)
        }
    }

    private var activeScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func request(_ orientations: UIInterfaceOrientationMask, in scene: UIWindowScene? = nil) {
        guard let scene = scene ?? activeScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
            AppLog.error("orientation update failed: \(error.localizedDescription)")
        }
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }
}
