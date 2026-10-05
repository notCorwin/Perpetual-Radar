import Foundation

struct MarketFilterCombination: Equatable {
    let id: String
    let name: String
    let filtersJSON: String

    var snapshot: [String: Any] {
        ["id": id, "name": name, "filtersJSON": filtersJSON]
    }
}

func normalizedMarketFilterCombinationName(_ value: String) -> String? {
    let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !name.isEmpty && name.count <= 80 ? name : nil
}
