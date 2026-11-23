import Foundation

public enum PackageVersion {
    public static func compare(_ left: String, _ right: String) -> ComparisonResult {
        let difference = compareValue(Array(left.unicodeScalars), Array(right.unicodeScalars))
        if difference < 0 { return .orderedAscending }
        if difference > 0 { return .orderedDescending }
        return .orderedSame
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 48 && scalar.value <= 57 }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func order(_ scalar: Unicode.Scalar?) -> Int {
        guard let scalar = scalar else { return 0 }
        if isDigit(scalar) { return 0 }
        if isLetter(scalar) { return Int(scalar.value) }
        if scalar == "~" { return -1 }
        return Int(scalar.value) + 256
    }

    private static func compareValue(_ left: [Unicode.Scalar], _ right: [Unicode.Scalar]) -> Int {
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < left.count || rightIndex < right.count {
            while (leftIndex < left.count && !isDigit(left[leftIndex])) || (rightIndex < right.count && !isDigit(right[rightIndex])) {
                let leftOrder = order(leftIndex < left.count ? left[leftIndex] : nil)
                let rightOrder = order(rightIndex < right.count ? right[rightIndex] : nil)
                if leftOrder != rightOrder { return leftOrder - rightOrder }
                leftIndex += 1
                rightIndex += 1
            }
            while leftIndex < left.count && left[leftIndex] == "0" { leftIndex += 1 }
            while rightIndex < right.count && right[rightIndex] == "0" { rightIndex += 1 }
            var firstDifference = 0
            while leftIndex < left.count && isDigit(left[leftIndex]) && rightIndex < right.count && isDigit(right[rightIndex]) {
                if firstDifference == 0 { firstDifference = Int(left[leftIndex].value) - Int(right[rightIndex].value) }
                leftIndex += 1
                rightIndex += 1
            }
            if leftIndex < left.count && isDigit(left[leftIndex]) { return 1 }
            if rightIndex < right.count && isDigit(right[rightIndex]) { return -1 }
            if firstDifference != 0 { return firstDifference }
        }
        return 0
    }
}
