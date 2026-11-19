import Foundation

public enum QQVisionProvider: String, Codable, CaseIterable, Sendable {
    case deepseek
    public var title: String { "当前模型原生识图" }
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard ["deepseek", "zhipu"].contains(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "不支持的识图服务"))
        }
        self = .deepseek
    }
}

// No credentials in persisted settings. Existing installations retain their provider until changed.
public struct QQVisualConfig: Codable, Equatable, Sendable {
    public var provider: QQVisionProvider = .deepseek
    public var googleWebEnabled = false
    public init() {}
}
