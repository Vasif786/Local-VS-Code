//
//  LanguageService.swift
//  Code
//
//  Created by Ken Chung on 09/08/2024.
//

import Foundation

class LanguageService {
    struct Configuration {
        let languageIdentifier: String
        let extensions: [String]
        let args: [String]
    }

    var candidateLanguageIdentifier: String? = nil

    static let shared = LanguageService()
    static let configurations: [Configuration] = [
        Configuration(
            languageIdentifier: "python",
            extensions: ["py"],
            args: ["jedi-language-server", "-v"]),
        Configuration(
            languageIdentifier: "java",
            extensions: ["java"],
            args: ["java", "-jar", "${JAVA_LSP_FAT_JAR_PATH}"]),
        // Dart analysis server. This is used by the existing Monaco LSP
        // bridge for local projects when the Dart SDK is available in the
        // Code App runtime/PATH. Remote SSH Dart projects use the analyzer
        // bridge in DartHybridIntelliSense, which does not require a second
        // persistent SSH terminal connection.
        Configuration(
            languageIdentifier: "dart",
            extensions: ["dart"],
            args: ["dart", "language-server", "--protocol=lsp"]),
    ]

    static func configurationFor(url: URL) -> Configuration? {
        return LanguageService.configurations.first(where: {
            $0.extensions.contains(url.pathExtension)
        })
    }
}
