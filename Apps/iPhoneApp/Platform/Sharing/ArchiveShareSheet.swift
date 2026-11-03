import SwiftUI
import UIKit
import MoMoArchive

/// Presents UIActivityViewController natively from a lightweight UIKit host controller
/// rather than embedding UIActivityViewController as a child inside SwiftUI's .sheet,
/// preventing double-modal dismissal deadlocks and missed completion callbacks.
struct ArchiveSharePresenter: UIViewControllerRepresentable {
    let artifact: ArchiveExport?
    let onCompleted: @MainActor (UUID, Bool, String?) -> Void
    let onDismissed: @MainActor (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        let coordinator = context.coordinator
        guard let artifact else {
            if let presented = coordinator.presentedController,
               presented.presentingViewController != nil,
               !presented.isBeingDismissed {
                presented.dismiss(animated: true)
            }
            return
        }
        guard coordinator.presentedID != artifact.id else { return }
        guard host.view.window != nil, host.presentedViewController == nil else {
            DispatchQueue.main.async { [weak host] in
                guard let host, coordinator.presentedID != artifact.id,
                      host.view.window != nil, host.presentedViewController == nil else { return }
                Self.present(artifact: artifact, from: host, coordinator: coordinator,
                             onCompleted: onCompleted, onDismissed: onDismissed)
            }
            return
        }
        Self.present(artifact: artifact, from: host, coordinator: coordinator,
                     onCompleted: onCompleted, onDismissed: onDismissed)
    }

    @MainActor
    private static func present(
        artifact: ArchiveExport,
        from host: UIViewController,
        coordinator: Coordinator,
        onCompleted: @escaping @MainActor (UUID, Bool, String?) -> Void,
        onDismissed: @escaping @MainActor (UUID) -> Void
    ) {
        let id = artifact.id
        coordinator.presentedID = id
        let controller = DismissObservingActivityViewController(
            activityItems: artifact.fileURLs,
            applicationActivities: nil
        )
        controller.onDidDisappearAfterDismissal = { [weak coordinator] in
            if coordinator?.presentedID == id {
                coordinator?.presentedController = nil
                coordinator?.presentedID = nil
            }
            onDismissed(id)
        }
        controller.completionWithItemsHandler = { _, completed, _, error in
            let message = error.map { String(localized: "分享未完成：\($0.localizedDescription)") }
            Task { @MainActor in
                onCompleted(id, completed, message)
            }
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = host.view
            popover.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        coordinator.presentedController = controller
        host.present(controller, animated: true)
    }

    final class Coordinator {
        weak var presentedController: UIActivityViewController?
        var presentedID: UUID?
    }
}

private final class DismissObservingActivityViewController: UIActivityViewController {
    var onDidDisappearAfterDismissal: (@MainActor () -> Void)?
    private var notifiedDismissal = false

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !notifiedDismissal, (isBeingDismissed || presentingViewController == nil) {
            notifiedDismissal = true
            let callback = onDidDisappearAfterDismissal
            onDidDisappearAfterDismissal = nil
            Task { @MainActor in callback?() }
        }
    }
}
