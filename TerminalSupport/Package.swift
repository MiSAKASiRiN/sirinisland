// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TerminalSupport",
    platforms: [.macOS(.v13)],
    products: [.library(name: "TerminalSupport", type: .static, targets: ["TerminalSupport"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "282c3c3a932b55c129628876b70f37d993af1615")],
    targets: [.target(name: "TerminalSupport", dependencies: ["SwiftTerm"])]
)
