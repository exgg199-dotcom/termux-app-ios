import Foundation

public enum PackageFormat {
    public static func size(_ bytes: Int64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB", "PB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while true {
            if value < 100 && unitIndex != 0 {
                return String(format: "%.1f", value) + " " + units[unitIndex]
            }
            if value < 10000 || unitIndex == units.count - 1 {
                return grouped(Int64(value.rounded())) + " " + units[unitIndex]
            }
            value /= 1000
            unitIndex += 1
        }
    }

    public static func rate(bytes: Int64, seconds: Double) -> String {
        let perSecond = seconds > 0.001 ? Double(bytes) / seconds : Double(bytes) * 1000
        return size(Int64(perSecond)) + "/s"
    }

    public static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)min \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)min"
    }

    public static func grouped(_ number: Int64) -> String {
        let digits = Array(String(abs(number)))
        var result = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return number < 0 ? "-" + result : result
    }
}
