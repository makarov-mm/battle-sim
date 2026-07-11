import Foundation

/// One decoded server frame.
struct Frame {
    var tick: UInt32
    var agents: [AgentWire]
    var events: [EventWire]
}

struct AgentWire {
    var id: UInt16
    var team: UInt8
    var kind: UInt8
    var state: UInt8
    var hp: UInt8
    var x: Float
    var z: Float
    var heading: Float
}

struct EventWire {
    var type: UInt8
    var a: UInt16
    var x1: Float
    var z1: Float
    var x2: Float
    var z2: Float
    var aux: UInt8
}

/// Connects to the Elixir server, decodes binary frames, hands them to World.
final class Net: NSObject, URLSessionWebSocketDelegate {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private let url: URL
    private weak var world: World?

    init(world: World, host: String = "127.0.0.1", port: Int = 4040) {
        self.world = world
        self.url = URL(string: "ws://\(host):\(port)/")!
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func start() {
        connect()
    }

    private func connect() {
        task = session.webSocketTask(with: url)
        task?.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .data(let data) = message {
                    self.decode(data)
                }
                self.receive()
            case .failure:
                // Reconnect after a short delay.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.connect()
                }
            }
        }
    }

    private func decode(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!
            var off = 0

            func u8() -> UInt8 { defer { off += 1 }; return base.load(fromByteOffset: off, as: UInt8.self) }
            func u16() -> UInt16 {
                let v = base.loadUnaligned(fromByteOffset: off, as: UInt16.self)
                off += 2
                return UInt16(littleEndian: v)
            }
            func i16() -> Int16 {
                let v = base.loadUnaligned(fromByteOffset: off, as: Int16.self)
                off += 2
                return Int16(littleEndian: v)
            }
            func u32() -> UInt32 {
                let v = base.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                off += 4
                return UInt32(littleEndian: v)
            }

            let tick = u32()
            let nAgents = Int(u16())
            let nEvents = Int(u16())

            var agents = [AgentWire]()
            agents.reserveCapacity(nAgents)
            for _ in 0..<nAgents {
                let id = u16()
                let flags = u8()
                let hp = u8()
                let x = Float(i16()) / 64.0
                let z = Float(i16()) / 64.0
                let heading = Float(i16()) / 10430.0
                agents.append(AgentWire(
                    id: id,
                    team: flags & 1,
                    kind: (flags >> 1) & 3,
                    state: (flags >> 3) & 7,
                    hp: hp,
                    x: x, z: z, heading: heading
                ))
            }

            var events = [EventWire]()
            events.reserveCapacity(nEvents)
            for _ in 0..<nEvents {
                let type = u8()
                let a = u16()
                let x1 = Float(i16()) / 64.0
                let z1 = Float(i16()) / 64.0
                let x2 = Float(i16()) / 64.0
                let z2 = Float(i16()) / 64.0
                let aux = u8()
                events.append(EventWire(type: type, a: a, x1: x1, z1: z1, x2: x2, z2: z2, aux: aux))
            }

            world?.ingest(Frame(tick: tick, agents: agents, events: events))
        }
    }
}
