#!/usr/bin/env swift

// AGENT: Apple Translation Framework CLI Tool
// AGENT: Requires macOS 15.0+ (Sequoia)
// AGENT: Compile: swiftc -o translate translate.swift
// AGENT: Usage: ./translate "Hello, World" --from en --to ko

import Foundation
import AppKit
import SwiftUI
import Translation
import NaturalLanguage

// MARK: - Command Line Arguments

struct CLIArguments {
    let text: String
    let sourceLanguage: String
    let targetLanguage: String

    // AGENT: Detect language using NaturalLanguage framework
    static func detectLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    static func parse() -> CLIArguments? {
        let args = CommandLine.arguments

        var text: String?
        var sourceLang: String? = nil // AGENT: nil means auto-detect
        var targetLang: String? = nil // AGENT: nil means auto-select based on source

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--from", "-f":
                if i + 1 < args.count {
                    sourceLang = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--to", "-t":
                if i + 1 < args.count {
                    targetLang = args[i + 1]
                    i += 2
                } else {
                    i += 1
                }
            case "--help", "-h":
                printUsage()
                return nil
            case "--list", "-l":
                printSupportedLanguages()
                return nil
            case "-":
                // AGENT: Explicit stdin marker
                text = readFromStdin()
                i += 1
            default:
                if text == nil {
                    text = args[i]
                }
                i += 1
            }
        }

        // AGENT: If no text argument, try reading from stdin (for piping)
        if text == nil {
            if let stdinText = readFromStdinIfAvailable() {
                text = stdinText
            }
        }

        guard let translationText = text, !translationText.isEmpty else {
            printUsage()
            return nil
        }

        // AGENT: Auto-detect source language if not specified
        let finalSourceLang: String
        if let src = sourceLang {
            finalSourceLang = src
        } else {
            finalSourceLang = detectLanguage(translationText) ?? "en"
        }

        // AGENT: Auto-select target language if not specified
        // AGENT: Korean source -> Japanese target, otherwise -> Korean target
        let finalTargetLang: String
        if let tgt = targetLang {
            finalTargetLang = tgt
        } else {
            finalTargetLang = (finalSourceLang == "ko") ? "ja" : "ko"
        }

        return CLIArguments(
            text: translationText,
            sourceLanguage: finalSourceLang,
            targetLanguage: finalTargetLang
        )
    }

    // AGENT: Read all input from stdin (blocking)
    static func readFromStdin() -> String? {
        var lines: [String] = []
        while let line = readLine() {
            lines.append(line)
        }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    // AGENT: Check if stdin has data available (non-blocking check)
    static func readFromStdinIfAvailable() -> String? {
        // AGENT: Check if stdin is a pipe or file (not a terminal)
        if isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            return readFromStdin()
        }
        return nil
    }

    static func printUsage() {
        let usage = """
        Apple Translation CLI Tool

        Usage: translate <text> [options]
            echo "text" | translate [options]
            translate - [options] < file.txt

        Options:
            --from, -f <lang>   Source language code (default: auto-detect)
            --to, -t <lang>     Target language code (default: auto-select)
            --list, -l          List supported language codes
            --help, -h          Show this help message
            -                   Read from stdin explicitly

        Auto-select behavior:
            - Source language is auto-detected from input text
            - If source is Korean (ko) -> target defaults to Japanese (ja)
            - Otherwise -> target defaults to Korean (ko)

        Examples:
            translate "Hello, World"              # auto: en -> ko
            translate "안녕하세요"                  # auto: ko -> ja
            translate "Bonjour" --to en           # auto: fr -> en (override target)
            translate "Hello" --from en --to ja   # explicit both
            echo "Hello" | translate
            cat document.txt | translate --to en

        Note: Requires macOS 15.0+ (Sequoia)
            Language packs must be downloaded in System Settings > General > Language & Region > Translation Languages
        """
        print(usage)
    }

    static func printSupportedLanguages() {
        let languages = """
        Supported Language Codes:

            ar    - Arabic
            de    - German
            en    - English
            es    - Spanish
            fr    - French
            hi    - Hindi
            id    - Indonesian
            it    - Italian
            ja    - Japanese
            ko    - Korean
            nl    - Dutch
            pl    - Polish
            pt    - Portuguese (Brazil)
            ru    - Russian
            th    - Thai
            tr    - Turkish
            uk    - Ukrainian
            vi    - Vietnamese
            zh-Hans - Chinese (Simplified)
            zh-Hant - Chinese (Traditional)

        Note: Download language packs in System Settings > General > Language & Region > Translation Languages
        """
        print(languages)
    }
}

// MARK: - Translation Manager

@available(macOS 15.0, *)
class TranslationManager: ObservableObject {
    @Published var isCompleted = false
    @Published var result: String?
    @Published var error: String?

    let textToTranslate: String
    let sourceLanguage: Locale.Language
    let targetLanguage: Locale.Language

    init(text: String, source: String, target: String) {
        self.textToTranslate = text
        self.sourceLanguage = Locale.Language(identifier: source)
        self.targetLanguage = Locale.Language(identifier: target)
    }

    func translate(using session: TranslationSession) async {
        do {
            // AGENT: Prepare translation (triggers language pack download if needed)
            try await session.prepareTranslation()

            let response = try await session.translate(textToTranslate)
            await MainActor.run {
                self.result = response.targetText
                self.isCompleted = true
            }
        } catch {
            await MainActor.run {
                self.error = "Translation error: \(error.localizedDescription)\n\nDebug info:\n- Error type: \(type(of: error))\n- Full error: \(error)"
                self.isCompleted = true
            }
        }
    }
}

// MARK: - Translation View

@available(macOS 15.0, *)
struct TranslationView: View {
    @ObservedObject var manager: TranslationManager
    let onComplete: () -> Void

    @State private var configuration: TranslationSession.Configuration?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                // AGENT: Configure with explicit source and target languages
                configuration = TranslationSession.Configuration(
                    source: manager.sourceLanguage,
                    target: manager.targetLanguage
                )
            }
            .translationTask(configuration) { session in
                await manager.translate(using: session)
            }
            .onChange(of: manager.isCompleted) { _, completed in
                if completed {
                    onComplete()
                }
            }
    }
}

// MARK: - App Delegate

@available(macOS 15.0, *)
class TranslationAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let args: CLIArguments
    var manager: TranslationManager?

    init(args: CLIArguments) {
        self.args = args
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mgr = TranslationManager(
            text: args.text,
            source: args.sourceLanguage,
            target: args.targetLanguage
        )
        self.manager = mgr

        let translationView = TranslationView(manager: mgr) { [weak self] in
            guard let self = self, let manager = self.manager else { return }

            if let result = manager.result {
                print(result)
            } else if let error = manager.error {
                fputs("\(error)\n", stderr)
            }

            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }

        let hostingView = NSHostingView(rootView: translationView)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window?.contentView = hostingView
        window?.orderBack(nil)
        window?.alphaValue = 0

        // AGENT: Set as accessory to hide from dock
        NSApp.setActivationPolicy(.accessory)

        // AGENT: Timeout after 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, let manager = self.manager else { return }
            if !manager.isCompleted {
                fputs("Error: Translation timed out after 30 seconds.\n", stderr)
                fputs("Make sure the required language packs are downloaded.\n", stderr)
                fputs("Go to: System Settings > General > Language & Region > Translation Languages\n", stderr)
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Main Entry Point

func main() {
    guard let args = CLIArguments.parse() else {
        exit(1)
    }

    if #available(macOS 15.0, *) {
        let app = NSApplication.shared
        let delegate = TranslationAppDelegate(args: args)
        app.delegate = delegate
        app.run()
    } else {
        fputs("Error: Translation framework requires macOS 15.0 (Sequoia) or later.\n", stderr)
        fputs("Current version: \(ProcessInfo.processInfo.operatingSystemVersionString)\n", stderr)
        exit(1)
    }
}

main()
