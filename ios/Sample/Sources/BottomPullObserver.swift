import SwiftUI
import UIKit

/// Observes the scroll view's own pan. A fling, layout change, or button
/// activation can't arm it, and the existing pull-to-refresh keeps its gesture.
struct BottomPullObserver: UIViewRepresentable {
    let onPull: () -> Void

    func makeUIView(context: Context) -> Observer {
        let view = Observer()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Observer, context: Context) {
        view.onPull = onPull
        view.attach()
    }

    static func dismantleUIView(_ view: Observer, coordinator: ()) {
        view.detach()
    }

    final class Observer: UIView {
        var onPull: (() -> Void)?
        private weak var scroll: UIScrollView?
        private var armed = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }

        func attach() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let next = ancestor as? UIScrollView, next !== scroll else { return }
            detach()
            scroll = next
            next.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
        }

        func detach() {
            scroll?.panGestureRecognizer.removeTarget(self, action: #selector(pan(_:)))
            scroll = nil
            armed = false
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let scroll else { return }
            switch gesture.state {
            case .changed:
                let bottom = max(-scroll.adjustedContentInset.top,
                                 scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let overscroll = scroll.contentOffset.y - bottom
                if overscroll > 28 && gesture.translation(in: scroll).y < 0 {
                    armed = true
                } else if overscroll < 8 {
                    armed = false
                }
            case .ended:
                let shouldLoad = armed
                armed = false
                if shouldLoad { onPull?() }
            default:
                armed = false
            }
        }
    }
}
