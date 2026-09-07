//
//  DartHybridIntelliSense.swift
//
//  Retained as a compatibility shim for existing Xcode target membership.
//  Dart/Flutter IntelliSense is now provided exclusively by the remote Dart
//  Language Server Protocol bridge in LanguageService.swift. No local Dart
//  analyzer, curated completion database, or one-shot `dart analyze` runner
//  is used.
//
import Foundation

final class DartHybridIntelliSense {
    static let shared = DartHybridIntelliSense()
    private init() {}

    func activate(app: MainApp, editorURL: URL, content: String) {}
    func scheduleAnalysis(app: MainApp, editorURL: URL, content: String) {}
}
