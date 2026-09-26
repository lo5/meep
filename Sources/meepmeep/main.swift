import AppKit
import Foundation
import Network

// MARK: - Configuration

let arguments = CommandLine.arguments
let defaultSoundsDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Sounds").path
let soundsDirectory = arguments.count > 1 ? arguments[1] : defaultSoundsDirectory
let socketPath = arguments.count > 2 ? arguments[2] : "/tmp/meepmeep.sock"

// NSSound handles these formats natively.
let audioExtensions: Set<String> = ["aiff", "aif", "wav", "au", "snd", "caf", "mp3", "m4a", "aac"]

// MARK: - Sound loading (all files read into memory once at startup)

var sounds: [String: NSSound] = [:]

func loadSounds(from directory: String) -> [String: NSSound] {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue,
          let files = try? fileManager.contentsOfDirectory(atPath: directory) else {
        fputs("meepmeep: warning: cannot read sound directory '\(directory)', starting with no sounds\n", stderr)
        return [:]
    }

    var loaded: [String: NSSound] = [:]
    for file in files.sorted() {
        let ext = (file as NSString).pathExtension.lowercased()
        guard audioExtensions.contains(ext) else { continue }

        let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
        // byReference: false -> the file is decoded fully into memory at load time;
        // subsequent play() calls hit memory only, with near-zero latency.
        guard let sound = NSSound(contentsOf: url, byReference: false) else {
            fputs("meepmeep: warning: could not load '\(file)', skipping\n", stderr)
            continue
        }

        let base = (file as NSString).deletingPathExtension
        // Register under the full filename ("beep.aiff") and, if not taken, the base name ("beep").
        loaded[file] = sound
        if loaded[base] == nil { loaded[base] = sound }
    }
    return loaded
}

// MARK: - Request handling
//
// One connection = one request. The message is a single JSON object,
// optionally followed by a newline:
//   {"name": "Glass.aiff", "volume": 0.5}
// `name` is the sound filename (or unique base name); `volume` is optional
// (defaults to 1.0) and clamped to [0.0, 1.0].
// Malformed JSON and unknown sound names are silently ignored (no playback,
// no error).

struct PlayRequest: Decodable {
    let name: String
    let volume: Double?
}

func clampedVolume(_ raw: Double) -> Double {
    return min(max(raw, 0.0), 1.0)
}

func handleRequest(_ data: Data?) {
    guard let data, !data.isEmpty,
          let request = try? JSONDecoder().decode(PlayRequest.self, from: data),
          let sound = sounds[request.name]
    else { return }  // malformed request or unknown sound -> do nothing

    sound.volume = Float(clampedVolume(request.volume ?? 1.0))
    sound.play()
}

// MARK: - Unix domain socket listener

sounds = loadSounds(from: soundsDirectory)

// Inode of the socket file this process created. Used so a shutting-down
// instance only unlinks its own socket, never one a newer instance just bound
// (which otherwise races on fast restarts).
func fileInode(at path: String) -> UInt64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let number = attrs[.systemFileNumber] as? NSNumber else { return nil }
    return number.uint64Value
}
var boundSocketInode: UInt64?

do {
    // Remove a stale socket file left over from a previous run, if any.
    try? FileManager.default.removeItem(atPath: socketPath)

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .unix(path: socketPath)
    let listener = try NWListener(using: parameters)

    listener.newConnectionHandler = { (connection: NWConnection) in
        connection.start(queue: DispatchQueue.main)
        connection.receiveMessage { data, _, _, _ in
            handleRequest(data)
            connection.cancel()
        }
    }

    listener.stateUpdateHandler = { (state: NWListener.State) in
        switch state {
        case .ready:
            boundSocketInode = fileInode(at: socketPath)
        case let .failed(error):
            fputs("meepmeep: listener failed: \(error)\n", stderr)
            exit(1)
        default:
            break
        }
    }

    listener.start(queue: DispatchQueue.main)
    print("meepmeep: \(sounds.count) sound(s) loaded from '\(soundsDirectory)', listening on \(socketPath)")

    // Clean up our socket file on SIGINT/SIGTERM. The sources must be kept
    // referenced or they get released and never fire. Only unlink if the path
    // still refers to the inode we created, so we don't delete a replacement
    // socket that a restarted instance just bound.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            if let inode = boundSocketInode, fileInode(at: socketPath) == inode {
                try? FileManager.default.removeItem(atPath: socketPath)
            }
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    RunLoop.main.run()
} catch {
    fputs("meepmeep: could not listen on '\(socketPath)': \(error)\n", stderr)
    exit(1)
}
