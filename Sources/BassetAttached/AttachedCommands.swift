import Basset
import BassetEntityComponent
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Vision)
import Vision
#endif

#if DEBUG
/// A command is the attached machine asking for one thing now — a screenshot, a tap —
/// rather than changing which instruments run. It shares the socket with desired state and
/// is told apart by its envelope, and it answers directly on the link with frames carrying
/// the same `commandId`, never through the readings pipeline, so an answer costs nothing to
/// the stream and waits behind nothing in it. The last frame of every answer is a `command`
/// entity whose `mechanismStatus` says how it went.
struct AttachedCommand: Equatable {
    let id: UInt32
    let name: String
    let arguments: [String: Any]

    static func == (lhs: AttachedCommand, rhs: AttachedCommand) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }

    static func decode(_ document: Data) -> AttachedCommand? {
        guard let object = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
              let command = object["command"] as? [String: Any],
              let id = (command["id"] as? NSNumber).map({ UInt32(truncating: $0) }),
              let name = command["name"] as? String
        else {
            return nil
        }

        return AttachedCommand(
            id: id,
            name: name,
            arguments: command["arguments"] as? [String: Any] ?? [:]
        )
    }

    func double(_ key: String) -> Double? {
        (arguments[key] as? NSNumber)?.doubleValue
    }

    func int(_ key: String) -> Int? {
        (arguments[key] as? NSNumber)?.intValue
    }

    func string(_ key: String) -> String? {
        arguments[key] as? String
    }

    func bool(_ key: String) -> Bool? {
        arguments[key] as? Bool
    }

    func point(_ xKey: String = "x", _ yKey: String = "y") -> CGPoint? {
        guard let x = double(xKey), let y = double(yKey) else {
            return nil
        }

        return CGPoint(x: x, y: y)
    }
}

enum AttachedCommands {
    static let screenshot = "screenshot"
    static let hierarchy = "hierarchy"
    static let hitTest = "hitTest"
    static let tap = "tap"
    static let longPress = "longPress"
    static let swipe = "swipe"
    static let type = "type"
    static let overlay = "overlay"
    static let keepAwake = "keepAwake"
    static let pause = "pause"
    static let screenText = "screenText"

    static let done = "done"

    static let cancelled = "cancelled"

    private static let queue: DispatchQueue = .init(label: "dev.basset.attached.commands")
    private static let lock: NSLock = .init()
    private nonisolated(unsafe) static var lastAnswer: Task<Void, Never>?

    /// True when `document` was a command, which has then been taken; false leaves it
    /// to be applied as desired state. Commands run one at a time in the order they
    /// arrived: two gestures in flight at once would interleave their fingers.
    static func handle(_ document: Data, reply: @escaping (Data) -> Void) -> Bool {
        guard let command = AttachedCommand.decode(document) else {
            return false
        }

        lock.withLock {
            let previous = lastAnswer
            lastAnswer = Task {
                await previous?.value
                for frame in await frames(answering: command) {
                    reply(frame)
                }
            }
        }
        return true
    }

    static func frames(answering command: AttachedCommand) async -> [Data] {
        let answer = await entities(answering: command)
        let encoder = FrameEncoder()
        return answer.map { entity in
            let tagged = Entity(
                id: entity.id,
                capturedAt: entity.capturedAt,
                components: entity.components + [.commandId(command.id)]
            )
            return encoder.frame(encoder.encode(tagged))
        }
    }

    static func finished(_ status: String = done, _ extra: [Component] = []) -> Entity {
        Entity(.command, components: [.mechanismStatus(status)] + extra)
    }

    static func overlayCancelled() -> Data {
        var out = Readings(.overlay)
        out.put(.mechanismStatus(cancelled))
        let encoder = FrameEncoder()
        return encoder.frame(encoder.encode(out.tagged(.deviceInfo)))
    }

    private static func entities(answering command: AttachedCommand) async -> [Entity] {
        switch command.name {
        case screenshot:
            let shot = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: Screenshot().reading()) }
            }
            return shot.allEntities(taggedAs: .screenshot) + [finished()]
        #if canImport(UIKit)
        case hierarchy:
            return await MainActor.run { ViewWalk.hierarchy() + [finished()] }
        case screenText:
            return await ScreenText.recognize()
        case hitTest:
            guard let point = command.point() else {
                return [finished("missing: x, y")]
            }

            return await MainActor.run { ViewWalk.hitTest(at: point) }
        case longPress,
             swipe,
             tap,
             type:
            return await Gestures.perform(command)
        case overlay:
            return await MainActor.run {
                guard command.bool("visible") ?? true else {
                    DrivingOverlay.hide()
                    return [finished()]
                }

                let shown = DrivingOverlay.show(
                    text: command.string("text") ?? "Basset is driving this app",
                    blocksTouches: command.bool("blocksTouches") ?? true,
                    onCancel: { BassetAttached.send(overlayCancelled()) }
                )
                return [finished(shown ? done : "noForegroundScene")]
            }
        case keepAwake:
            return await MainActor.run {
                KeepAwake.hold(command.bool("awake") ?? true)
                return [finished(done, [.settingEnabled(KeepAwake.isHeld)])]
            }
        #endif
        case pause:
            do {
                try AttachedBridge.pause(command.bool("paused") ?? true)
                return [finished()]
            } catch {
                return [finished("\(error)")]
            }
        default:
            return [finished("unknown command: \(command.name)")]
        }
    }
}

#if canImport(UIKit)
@MainActor
enum ViewWalk {
    private static let textLimit = 80

    static func hierarchy() -> [Entity] {
        guard let window = SyntheticTouch.keyWindow() else {
            return [AttachedCommands.finished("noKeyWindow")]
        }

        var rows = [Entity]()
        walk(window, in: window, parent: 0, level: 0, into: &rows)
        return rows
    }

    static func hitTest(at point: CGPoint) -> [Entity] {
        guard let window = SyntheticTouch.keyWindow() else {
            return [AttachedCommands.finished("noKeyWindow")]
        }

        var out = Readings(.viewHierarchy)
        ViewsAtPoint.write(at: point, in: window, parent: 0, into: &out)
        let hit = window.hitTest(point, with: nil)
        var extra: [Component] = [.originXPoints(Double(point.x)), .originYPoints(Double(point.y))]
        if let hit {
            extra.append(.runtimeClassName(NSStringFromClass(Swift.type(of: hit))))
            extra.append(.interactionEnabled(hit.isUserInteractionEnabled))
        }
        return out.allEntities(taggedAs: .viewHierarchy)
            + [AttachedCommands.finished(hit == nil ? "noHit" : AttachedCommands.done, extra)]
    }

    private static func walk(
        _ view: UIView,
        in window: UIWindow,
        parent: UInt32,
        level: UInt32,
        into rows: inout [Entity]
    ) {
        guard !view.isHidden, view.alpha > 0.01 else {
            return
        }

        let id = EntityIdentity.next()
        let frame = view.convert(view.bounds, to: window)
        var components: [Component] = [
            .runtimeClassName(NSStringFromClass(Swift.type(of: view))),
            .originXPoints(Double(frame.origin.x)),
            .originYPoints(Double(frame.origin.y)),
            .frameWidthPoints(Double(frame.width)),
            .frameHeightPoints(Double(frame.height)),
            .viewId(id),
            .viewParent(parent),
            .nestedLevel(level),
            .interactionEnabled(view.isUserInteractionEnabled),
        ]
        if let identifier = view.accessibilityIdentifier, !identifier.isEmpty {
            components.append(.accessibilityIdentifier(identifier))
        }
        if view is UIControl, let label = view.accessibilityLabel, !label.isEmpty {
            components.append(.accessibilityLabel(label))
        }
        if let text = text(of: view) {
            components.append(.viewText(text))
        }
        let recognizers = (view.gestureRecognizers ?? [])
            .map { NSStringFromClass(Swift.type(of: $0)) }
            .joined(separator: ",")
        if !recognizers.isEmpty {
            components.append(.recognizerClasses(recognizers))
        }
        rows.append(Entity(.viewHierarchy, components: components))

        for subview in view.subviews {
            walk(subview, in: window, parent: id, level: level + 1, into: &rows)
        }
    }

    private static func text(of view: UIView) -> String? {
        let raw: String? =
            switch view {
            case let label as UILabel: label.text
            case let button as UIButton: button.currentTitle
            case let field as UITextField: field.placeholder
            default: nil
            }
        guard let raw, !raw.isEmpty else {
            return nil
        }

        return raw.count > textLimit ? String(raw.prefix(textLimit)) + "…" : raw
    }
}

/// What is written on the screen and where, read from a render of the key window the way
/// a person reads it: SwiftUI, Metal and custom drawing put no view behind their text, so
/// this is the locator for them. Each line comes back as a row with its frame in window
/// points; a tap goes to the centre of the row.
enum ScreenText {
    private struct Rendered {
        let image: CGImage
        let size: CGSize
    }

    static func recognize() async -> [Entity] {
        #if canImport(Vision)
        guard let rendered = await MainActor.run(body: render) else {
            return [AttachedCommands.finished("noKeyWindow")]
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: rendered.image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return [AttachedCommands.finished("recognitionFailed: \(error)")]
        }

        var rows = [Entity]()
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else {
                continue
            }

            let box = observation.boundingBox
            let frame = CGRect(
                x: box.minX * rendered.size.width,
                y: (1 - box.maxY) * rendered.size.height,
                width: box.width * rendered.size.width,
                height: box.height * rendered.size.height
            )
            rows.append(Entity(.viewHierarchy, components: [
                .runtimeClassName("text"),
                .originXPoints(Double(frame.origin.x)),
                .originYPoints(Double(frame.origin.y)),
                .frameWidthPoints(Double(frame.width)),
                .frameHeightPoints(Double(frame.height)),
                .viewId(EntityIdentity.next()),
                .viewText(candidate.string),
                .detail(String(format: "confidence %.2f", candidate.confidence)),
            ]))
        }
        return rows + [AttachedCommands.finished()]
        #else
        return [AttachedCommands.finished("unsupported: Vision is not available")]
        #endif
    }

    @MainActor
    private static func render() -> Rendered? {
        guard let window = SyntheticTouch.keyWindow() else {
            return nil
        }

        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        guard let cgImage = image.cgImage else {
            return nil
        }

        return Rendered(image: cgImage, size: bounds.size)
    }
}

/// Gestures are phases on the main thread, one per run-loop turn, paced at a display
/// frame so a long press spans real time and a pan carries a velocity.
enum Gestures {
    private static let frameInterval: Duration = .milliseconds(8)
    private static let defaultLongPressMs = 800
    private static let defaultSwipeMs = 300

    static func perform(_ command: AttachedCommand) async -> [Entity] {
        do {
            switch command.name {
            case AttachedCommands.tap:
                guard let point = command.point() else {
                    return [AttachedCommands.finished("missing: x, y")]
                }

                let hit = try await tap(at: point, count: max(1, command.int("count") ?? 1))
                return [AttachedCommands.finished(AttachedCommands.done, describe(hit, point))]
            case AttachedCommands.longPress:
                guard let point = command.point() else {
                    return [AttachedCommands.finished("missing: x, y")]
                }

                let milliseconds = command.int("durationMs") ?? defaultLongPressMs
                let hit = try await hold(at: point, milliseconds: milliseconds)
                return [AttachedCommands.finished(AttachedCommands.done, describe(hit, point))]
            case AttachedCommands.swipe:
                guard let from = command.point("fromX", "fromY"),
                      let to = command.point("toX", "toY")
                else {
                    return [AttachedCommands.finished("missing: fromX, fromY, toX, toY")]
                }

                let milliseconds = command.int("durationMs") ?? defaultSwipeMs
                let hit = try await drag(from: from, to: to, milliseconds: milliseconds)
                return [AttachedCommands.finished(AttachedCommands.done, describe(hit, from))]
            case AttachedCommands.type:
                guard let text = command.string("text") else {
                    return [AttachedCommands.finished("missing: text")]
                }

                let status = await type(text, perCharacterMs: command.int("perCharMs") ?? 0)
                return [AttachedCommands.finished(status)]
            default:
                return [AttachedCommands.finished("unknown command: \(command.name)")]
            }
        } catch {
            return [AttachedCommands.finished("\(error)")]
        }
    }

    private static func describe(_ hit: UIView?, _ point: CGPoint) -> [Component] {
        var components: [Component] = [
            .originXPoints(Double(point.x)),
            .originYPoints(Double(point.y)),
        ]
        if let hit {
            components.append(.runtimeClassName(NSStringFromClass(Swift.type(of: hit))))
        }
        return components
    }

    @MainActor
    private static func begin(at point: CGPoint, tapCount: Int) throws -> SyntheticTouch {
        guard let window = SyntheticTouch.keyWindow() else {
            throw SyntheticTouch.Unsupported.noKeyWindow
        }

        let touch = try SyntheticTouch(at: point, in: window, tapCount: tapCount)
        try touch.send(.began, at: point)
        return touch
    }

    /// Anything thrown after the finger goes down, cancellation included, still lifts it.
    private static func withFinger(
        at point: CGPoint,
        tapCount: Int = 1,
        _ body: (SyntheticTouch) async throws -> Void
    ) async throws -> UIView? {
        let touch = try await begin(at: point, tapCount: tapCount)
        do {
            try await body(touch)
        } catch {
            await MainActor.run { touch.cancel() }
            throw error
        }
        return touch.hitView
    }

    /// The second finger of a double tap carries `tapCount` 2, the way UIKit stamps a
    /// real one, so a recognizer asking for two taps sees them.
    private static func tap(at point: CGPoint, count: Int) async throws -> UIView? {
        var hit: UIView?
        for index in 0 ..< count {
            hit = try await withFinger(at: point, tapCount: index + 1) { touch in
                try await Task.sleep(for: frameInterval)
                try await MainActor.run { try touch.send(.ended, at: point) }
                try await Task.sleep(for: frameInterval)
            }
        }
        return hit
    }

    private static func hold(at point: CGPoint, milliseconds: Int) async throws -> UIView? {
        try await withFinger(at: point) { touch in
            let deadline = ContinuousClock.now + .milliseconds(milliseconds)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: frameInterval)
                try await MainActor.run { try touch.send(.stationary, at: point) }
            }
            try await MainActor.run { try touch.send(.ended, at: point) }
        }
    }

    private static func drag(from: CGPoint, to: CGPoint,
                             milliseconds: Int) async throws -> UIView?
    {
        try await withFinger(at: from) { touch in
            let steps = max(2, milliseconds / 8)
            for step in 1...steps {
                try await Task.sleep(for: frameInterval)
                let fraction = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(
                    x: from.x + (to.x - from.x) * fraction,
                    y: from.y + (to.y - from.y) * fraction
                )
                try await MainActor.run { try touch.send(.moved, at: point) }
            }
            try await Task.sleep(for: frameInterval)
            try await MainActor.run { try touch.send(.ended, at: to) }
        }
    }

    private static func type(_ text: String, perCharacterMs: Int) async -> String {
        let responder = await MainActor.run { firstResponder() }
        guard let input = responder as? (any UIKeyInput) else {
            return "noFirstResponder"
        }

        for character in text {
            await MainActor.run { input.insertText(String(character)) }
            if perCharacterMs > 0 {
                try? await Task.sleep(for: .milliseconds(perCharacterMs))
            }
        }
        return AttachedCommands.done
    }

    @MainActor
    private static func firstResponder() -> UIResponder? {
        guard let window = SyntheticTouch.keyWindow() else {
            return nil
        }

        return find(firstResponderIn: window)
    }

    @MainActor
    private static func find(firstResponderIn view: UIView) -> UIResponder? {
        if view.isFirstResponder {
            return view
        }
        for subview in view.subviews {
            if let found = find(firstResponderIn: subview) {
                return found
            }
        }
        return nil
    }
}
#endif
#endif
