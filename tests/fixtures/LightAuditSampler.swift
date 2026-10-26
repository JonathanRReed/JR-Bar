import Foundation

// Compiled with the production JRBarLEDS sources by the Python audit.
@main struct LightAuditSampler {
    struct Request: Decodable {
        let program: String
        let leds: Int
        let times: [Int]
    }

    static func main() throws {
        let requests = try JSONDecoder().decode([Request].self, from: FileHandle.standardInput.readDataToEndOfFile())
        let frames = try requests.map { request in
            let program = try LEDSProgram.parse(request.program, ledCount: request.leds)
            let sampler = LEDSSampler(program: program, ledCount: request.leds, outputLedCount: 8)
            return request.times.map { time in
                sampler.codes(atMilliseconds: time).map { [Int($0.r), Int($0.g), Int($0.b)] }
            }
        }
        FileHandle.standardOutput.write(try JSONEncoder().encode(frames))
    }
}
