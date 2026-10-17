import Foundation

/// How a linked Screen Bar reads the strip's sampled drive colors.
public struct CoreStripTransfer: Codable, Hashable, Sendable {
    public let channelGains: [Double]
    public let displayChannelGains: [Double]
    public let codeToLightExponent: Double

    public init?(channelGains: [Double], displayChannelGains: [Double] = [1, 1, 1],
                 codeToLightExponent: Double = 1) {
        guard channelGains.count == 3, displayChannelGains.count == 3,
              (channelGains + displayChannelGains).allSatisfy({ $0.isFinite && (0.3...1.5).contains($0) }),
              codeToLightExponent.isFinite, (0.1...4).contains(codeToLightExponent) else { return nil }
        self.channelGains = channelGains
        self.displayChannelGains = displayChannelGains
        self.codeToLightExponent = codeToLightExponent
    }

    enum CodingKeys: String, CodingKey {
        case channelGains = "channel_gains"
        case displayChannelGains = "display_channel_gains"
        case codeToLightExponent = "code_to_light_exponent"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let source = try fields.decode([Double].self, forKey: .channelGains)
        let display = try fields.decodeIfPresent([Double].self, forKey: .displayChannelGains) ?? [1, 1, 1]
        let exponent = try fields.decode(Double.self, forKey: .codeToLightExponent)
        guard let transfer = Self(channelGains: source, displayChannelGains: display,
                                  codeToLightExponent: exponent) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: "Invalid strip color transfer"))
        }
        self = transfer
    }
}
