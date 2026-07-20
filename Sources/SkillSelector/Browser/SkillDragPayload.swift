import SwiftUI
import UniformTypeIdentifiers

struct SkillDragPayload: Transferable, Codable {
    let path: String
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
