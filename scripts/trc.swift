#!/usr/bin/env swift

// AGENT: Apple Translation Framework CLI Tool (Clipboard variant)
// AGENT: Requires macOS 15.0+ (Sequoia)
// AGENT: Usage: ./trc [--from en] [--to ko]
// AGENT: Input text is read from the system clipboard by default.

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

    // AGENT: Read text from the system clipboard
    static func readFromClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    static func parse() -> CLIArguments? {
        let args = CommandLine.arguments

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
            default:
                i += 1
            }
        }

        // AGENT: Input text always comes from the clipboard
        guard let translationText = readFromClipboard() else {
            fputs("Error: Clipboard is empty or does not contain text.\n", stderr)
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

    static func printUsage() {
        let usage = """
        Apple Translation CLI Tool (Clipboard)

        Usage: trc [options]

        Reads input text from the system clipboard and prints the translation to stdout.

        Options:
            --from, -f <lang>   Source language code (default: auto-detect)
            --to, -t <lang>     Target language code (default: auto-select)
            --list, -l          List supported language codes
            --help, -h          Show this help message

        Auto-select behavior:
            - Source language is auto-detected from clipboard text
            - If source is Korean (ko) -> target defaults to Japanese (ja)
            - Otherwise -> target defaults to Korean (ko)

        Examples:
            trc                    # translate clipboard contents with auto-detected languages
            trc --to en            # override target language
            trc --from en --to ja  # explicit both

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
