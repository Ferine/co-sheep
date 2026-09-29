import Foundation
import Testing
@testable import CoSheepKit

extension BrainTests {
    /// Unparseable user files are moved aside, never overwritten with defaults.
    @Suite("quarantine")
    struct QuarantineTests {
        private func corruptCopies(_ name: String, in dir: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasPrefix("\(name).corrupt-") }
        }

        @Test func corruptOpinionsAreMovedAsideBeforeTheFreshBrainIsSaved() throws {
            withBrainRoot { root in
                let garbage = Data("{ \"opinions\": [ oops".utf8)
                try? JSONFile.writeData(garbage, to: Paths.opinions)

                Memory.recordInteraction("petted main")   // load → default brain → save

                let aside = corruptCopies("opinions.json", in: root)
                #expect(aside.count == 1)
                if let name = aside.first {
                    let kept = try? Data(contentsOf: root.appendingPathComponent(name))
                    #expect(kept == garbage)
                }
                #expect(JSONFile.read(SheepBrain.self, from: Paths.opinions) != nil)
            }
        }

        @Test func invalidLivingStateIsMovedAside() {
            withBrainRoot { root in
                try? JSONFile.writeData(Data("{ nope".utf8), to: Paths.livingState("drama"))
                #expect(LivingState.loadState("drama") == .null)
                #expect(corruptCopies("drama.json", in: root).count == 1)
                #expect(!FileManager.default.fileExists(atPath: Paths.livingState("drama").path))
            }
        }

        @Test func validFilesAreLeftAlone() {
            withBrainRoot { root in
                Memory.recordInteraction("petted main")
                _ = Memory.loadBrain()
                #expect(corruptCopies("opinions.json", in: root).isEmpty)
            }
        }
    }
}
