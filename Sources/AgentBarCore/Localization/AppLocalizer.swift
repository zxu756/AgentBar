import Combine
import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var badge: String {
        switch self {
        case .zhHans: return "中文"
        case .en: return "EN"
        }
    }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public static func parseCLI(_ raw: String) -> AppLanguage? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "zh" || normalized.hasPrefix("zh-") || normalized.hasPrefix("zh_") {
            return .zhHans
        }
        if normalized == "en" || normalized.hasPrefix("en-") || normalized.hasPrefix("en_") {
            return .en
        }
        return nil
    }
}

public protocol PreferenceStore: AnyObject {
    func string(forKey defaultName: String) -> String?
    func integer(forKey defaultName: String) -> Int
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

public final class InMemoryPreferenceStore: PreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    public init(initialValues: [String: Any] = [:]) {
        self.storage = initialValues
    }

    public func string(forKey defaultName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[defaultName] as? String
    }

    public func integer(forKey defaultName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let intVal = storage[defaultName] as? Int {
            return intVal
        }
        if let num = storage[defaultName] as? NSNumber {
            return num.intValue
        }
        return 0
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            storage[defaultName] = value
        } else {
            storage.removeValue(forKey: defaultName)
        }
    }
}

@MainActor
public final class AppLocalizer: ObservableObject {
    nonisolated public static let defaultPreferenceKey = "local.xu.AgentBar.language"
    public static let shared = AppLocalizer()

    @Published public var language: AppLanguage {
        didSet {
            guard persistChanges else { return }
            preferenceStore.set(language.rawValue, forKey: preferenceKey)
        }
    }

    public let preferenceKey: String
    private let preferenceStore: PreferenceStore
    private var persistChanges: Bool

    public init(
        arguments: [String] = CommandLine.arguments,
        preferenceStore: PreferenceStore = UserDefaults.standard,
        preferenceKey: String = AppLocalizer.defaultPreferenceKey,
        preferredLanguages: [String] = Locale.preferredLanguages,
        persistCLI: Bool = false
    ) {
        self.preferenceStore = preferenceStore
        self.preferenceKey = preferenceKey
        self.persistChanges = true

        if let cliLang = Self.resolveCLILanguage(from: arguments) {
            self.persistChanges = persistCLI
            self.language = cliLang
            self.persistChanges = true
        } else if let saved = preferenceStore.string(forKey: preferenceKey),
                  let parsed = AppLanguage(rawValue: saved) ?? AppLanguage.parseCLI(saved) {
            self.language = parsed
        } else if let firstPreferred = preferredLanguages.first,
                  firstPreferred.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("zh") {
            self.language = .zhHans
        } else {
            self.language = .en
        }
    }

    public convenience init(
        arguments: [String] = CommandLine.arguments,
        userDefaults: UserDefaults,
        preferenceKey: String = AppLocalizer.defaultPreferenceKey,
        preferredLanguages: [String] = Locale.preferredLanguages,
        persistCLI: Bool = false
    ) {
        self.init(
            arguments: arguments,
            preferenceStore: userDefaults,
            preferenceKey: preferenceKey,
            preferredLanguages: preferredLanguages,
            persistCLI: persistCLI
        )
    }

    public init(fixedLanguage: AppLanguage) {
        self.preferenceStore = InMemoryPreferenceStore()
        self.preferenceKey = Self.defaultPreferenceKey
        self.persistChanges = false
        self.language = fixedLanguage
    }

    public var isChinese: Bool {
        language == .zhHans
    }

    public func L(_ en: String, _ zh: String) -> String {
        language == .zhHans ? zh : en
    }

    public func toggle() {
        language = (language == .zhHans) ? .en : .zhHans
    }

    public static func resolveCLILanguage(from arguments: [String]) -> AppLanguage? {
        for (idx, arg) in arguments.enumerated() {
            if arg == "--lang", idx + 1 < arguments.count {
                if let resolved = AppLanguage.parseCLI(arguments[idx + 1]) {
                    return resolved
                }
            } else if arg.hasPrefix("--lang=") {
                let value = String(arg.dropFirst("--lang=".count))
                if let resolved = AppLanguage.parseCLI(value) {
                    return resolved
                }
            }
        }
        return nil
    }
}

public struct LanguageTogglePill: View {
    @ObservedObject public var localizer: AppLocalizer
    public var compact: Bool

    @MainActor
    public init(localizer: AppLocalizer? = nil, compact: Bool = false) {
        self.localizer = localizer ?? .shared
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(AppLanguage.allCases) { lang in
                let isSelected = localizer.language == lang
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 1.0)) {
                        localizer.language = lang
                    }
                } label: {
                    Text(lang.badge)
                        .font(.system(size: compact ? 11 : 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? AgentBarPalette.ink : AgentBarPalette.muted)
                        .padding(.horizontal, compact ? 8 : 10)
                        .padding(.vertical, compact ? 3.5 : 5)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? AgentBarPalette.raised : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(
                                    isSelected ? AgentBarPalette.copper.opacity(0.55) : Color.clear,
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(AgentBarPalette.well)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(AgentBarPalette.rule, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help(localizer.L("Toggle language (⇧⌘L)", "切换语言 (⇧⌘L)"))
    }
}
