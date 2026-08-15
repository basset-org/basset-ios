@testable import Basset
import BassetECS
import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
@MainActor
struct ViewHierarchyWalkTests {
    @Test func aPointInsideNestedViewsReportsBothTopmostFirst() {
        let outer = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let inner = UIView(frame: CGRect(x: 10, y: 10, width: 50, height: 50))
        outer.addSubview(inner)

        let hits = rows(at: CGPoint(x: 20, y: 20), in: outer)

        #expect(hits.count == 2)
        #expect(value(.originXPoints, in: hits[0]) == "10.0")
        #expect(value(.originXPoints, in: hits[1]) == "0.0")
    }

    @Test func aPointOutsideEveryViewReportsUnavailable() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))

        let hits = rows(at: CGPoint(x: 500, y: 500), in: root)

        #expect(hits.count == 1)
        #expect(hits[0].components.contains { $0.id == .mechanismStatus })
    }

    @Test func aHiddenSubviewIsExcluded() {
        let outer = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let hidden = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        hidden.isHidden = true
        outer.addSubview(hidden)

        #expect(rows(at: CGPoint(x: 5, y: 5), in: outer).count == 1)
    }

    @Test func aTransparentSubviewIsExcluded() {
        let outer = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let transparent = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        transparent.alpha = 0
        outer.addSubview(transparent)

        #expect(rows(at: CGPoint(x: 5, y: 5), in: outer).count == 1)
    }

    @Test func theCallerSuppliedParentIsCarriedOnTheRootRow() {
        let outer = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let inner = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        outer.addSubview(inner)

        let hits = rows(at: CGPoint(x: 5, y: 5), in: outer, parent: 42)

        #expect(hits.count == 2)
        #expect(value(.entityParent, in: hits[1]) == "42")
        #expect(value(.nestedLevel, in: hits[1]) == "0")
    }

    @Test func aNestedMatchPointsAtItsAncestorsEntityId() {
        let outer = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let inner = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        outer.addSubview(inner)

        let hits = rows(at: CGPoint(x: 5, y: 5), in: outer)

        #expect(hits.count == 2)
        let outerId = value(.entityId, in: hits[1])
        #expect(value(.entityParent, in: hits[0]) == outerId)
        #expect(value(.nestedLevel, in: hits[0]) == "1")
    }

    @Test func moreThanTheCeilingIsTruncatedWithACount() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        for _ in 0 ..< (ViewHierarchy.ceiling + 5) {
            root.addSubview(UIView(frame: root.bounds))
        }

        let hits = rows(at: CGPoint(x: 5, y: 5), in: root)

        #expect(hits.count == ViewHierarchy.ceiling + 1)
        #expect(hits.last
            .flatMap { value(.mechanismStatus, in: $0) }?
            .contains("truncated") == true)
    }

    /// Every flat child's `parent` is the root — which a naive prefix cut drops, since the
    /// walk emits the root itself last. Genuinely truncated (`root.subviews.count` alone
    /// clears the ceiling), unlike a single nested chain, where closing one match's ancestors
    /// closes the whole chain and nothing is ever truncated.
    @Test func everyKeptRowsParentResolvesToAnEmittedEntityIdEvenWhenTruncated() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        for _ in 0 ..< (ViewHierarchy.ceiling + 10) {
            root.addSubview(UIView(frame: root.bounds))
        }

        let hits = rows(at: CGPoint(x: 5, y: 5), in: root)

        #expect(hits.last
            .flatMap { value(.mechanismStatus, in: $0) }?
            .contains("truncated") == true)

        let emittedIds = Set(hits.compactMap { value(.entityId, in: $0) })
        for entity in hits {
            guard let parentId = value(.entityParent, in: entity), parentId != "0" else {
                continue
            }

            #expect(emittedIds.contains(parentId))
        }
    }

    private func rows(at point: CGPoint, in root: UIView, parent: UInt32 = 0) -> [Entity] {
        var out = Readings(entity: .viewHierarchy, instrumentName: InstrumentID.viewHierarchy.name)
        ViewHierarchy.writeMatches(at: point, in: root, parent: parent, into: &out)
        return [out.sealed()] + out.sealedSiblings()
    }

    private func value(_ id: Component.ID, in entity: Entity) -> String? {
        entity.components.first { $0.id == id }?.value.rendered
    }
}
#endif
