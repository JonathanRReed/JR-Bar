import Foundation
import Testing
@testable import JRBarCore

@Suite("Strip light transfer protocol")
struct CoreStripTransferTests {
    @Test("surface transfer is additive and invalid metadata does not discard the program")
    func optionalTransfer() throws {
        let legacy = try JSONDecoder().decode(CoreLightSurface.self, from: Data(#"{"program":"off"}"#.utf8))
        #expect(legacy.stripTransfer == nil)
        let valid = try JSONDecoder().decode(CoreLightSurface.self, from: Data(
            ##"{"program":"#10071F","strip_transfer":{"channel_gains":[1,0.38,1],"display_channel_gains":[1,1,1],"code_to_light_exponent":1}}"##.utf8))
        #expect(valid.stripTransfer?.channelGains == [1, 0.38, 1])
        let roundTrip = try JSONDecoder().decode(CoreLightSurface.self, from: JSONEncoder().encode(valid))
        #expect(roundTrip == valid)
        let malformed = try JSONDecoder().decode(CoreLightSurface.self, from: Data(
            #"{"program":"off","strip_transfer":{"channel_gains":[1,0],"code_to_light_exponent":0}}"#.utf8))
        #expect(malformed.program == "off" && malformed.stripTransfer == nil)
        #expect(CoreStripTransfer(channelGains: [1, .nan, 1]) == nil)
        #expect(CoreStripTransfer(channelGains: [1, 1, 1], codeToLightExponent: .infinity) == nil)
    }
}
