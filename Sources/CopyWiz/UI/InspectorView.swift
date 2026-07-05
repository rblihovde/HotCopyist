import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The "behind the hood" view: every pasteboard representation of an item,
/// decoded as text / property list / image where possible, hex-dumped
/// otherwise. This is where you find out what Finale really puts on the
/// clipboard when you copy a measure.
struct InspectorView: View {
    let item: ClipboardItem
    let monitor: ClipboardMonitor
    var onClose: () -> Void

    @State private var selectedRepIndex = 0
    @State private var mode: DecodeMode = .auto

    enum DecodeMode: String, CaseIterable {
        case auto = "AUTO"
        case text = "TEXT"
        case hex = "HEX"
    }

    private var currentRep: ClipboardItem.Representation? {
        guard item.reps.indices.contains(selectedRepIndex) else { return item.reps.first }
        return item.reps[selectedRepIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)

            header
            typeChips
            modeBar

            Rectangle().fill(Theme.hairline).frame(height: 1)

            content
        }
        .background(Color.black.opacity(0.28))
        .onChange(of: item.id) { _, _ in
            selectedRepIndex = 0
            mode = .auto
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("PAYLOAD INSPECTOR")
                    .font(Theme.monoSmall)
                    .tracking(2)
                    .foregroundStyle(Theme.mint)

                Spacer()

                headerButton("COPY DUMP") { copyDump() }
                headerButton("EXPORT .BIN") { exportRaw() }

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Close inspector")
            }

            Text(metaString)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    private func headerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.monoSmall)
                .tracking(1)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var metaString: String {
        var parts: [String] = []
        if let app = item.sourceAppName { parts.append(app.uppercased()) }
        parts.append(Fmt.full.string(from: item.copiedAt).uppercased())
        parts.append(Fmt.size(item.totalBytes).uppercased())
        parts.append("\(item.reps.count) \(item.reps.count == 1 ? "REPRESENTATION" : "REPRESENTATIONS")")
        return parts.joined(separator: " · ")
    }

    // MARK: - Type chips

    private var typeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(Array(item.reps.enumerated()), id: \.offset) { index, rep in
                    let selected = index == selectedRepIndex
                    Button {
                        selectedRepIndex = index
                    } label: {
                        HStack(spacing: 5) {
                            Text(rep.type)
                                .font(Theme.monoSmall)
                                .foregroundStyle(selected ? Theme.mint : Theme.textPrimary.opacity(0.8))
                            Text(Fmt.size(rep.data.count))
                                .font(Theme.monoSmall)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Theme.mint.opacity(0.1) : Color.white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(selected ? Theme.mint.opacity(0.5) : Theme.hairline, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Mode bar

    private var modeBar: some View {
        HStack(spacing: 4) {
            ForEach(DecodeMode.allCases, id: \.self) { candidate in
                let selected = candidate == mode
                Button {
                    mode = candidate
                } label: {
                    Text(candidate.rawValue)
                        .font(Theme.monoSmall)
                        .tracking(1)
                        .foregroundStyle(selected ? Color.black : Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(selected ? Theme.mint.opacity(0.85) : Color.white.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(typeInfoString)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var typeInfoString: String {
        guard let rep = currentRep else { return "" }
        if let utType = UTType(rep.type), let description = utType.localizedDescription, !description.isEmpty {
            return description.uppercased()
        }
        return "UNREGISTERED / APP-PRIVATE TYPE"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            switch decodedPayload {
            case .image(let nsImage):
                VStack(spacing: 6) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text("\(Int(nsImage.size.width)) × \(Int(nsImage.size.height)) pt")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            case .text(let string):
                Text(string)
                    .font(Theme.monoData)
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var decodedPayload: PayloadDecoder.Payload {
        guard let rep = currentRep else { return .text("(no data)") }
        switch mode {
        case .auto:
            return PayloadDecoder.auto(rep.data, type: rep.type)
        case .text:
            return .text(String(decoding: rep.data, as: UTF8.self))
        case .hex:
            return .text(PayloadDecoder.hexDump(rep.data))
        }
    }

    // MARK: - Actions

    private func copyDump() {
        guard let rep = currentRep else { return }
        var dump = "CopyWiz payload dump\n"
        dump += "type: \(rep.type)\n"
        dump += "size: \(rep.data.count) bytes\n"
        if let app = item.sourceAppName { dump += "source: \(app)\n" }
        dump += "copied: \(Fmt.full.string(from: item.copiedAt))\n\n"
        switch PayloadDecoder.auto(rep.data, type: rep.type) {
        case .text(let string):
            dump += string
        case .image:
            dump += PayloadDecoder.hexDump(rep.data)
        }
        monitor.copyText(dump)
    }

    private func exportRaw() {
        guard let rep = currentRep else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = rep.type
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            + ".bin"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? rep.data.write(to: url)
        }
    }
}

// MARK: - Decoding

enum PayloadDecoder {

    enum Payload {
        case text(String)
        case image(NSImage)
    }

    static func auto(_ data: Data, type: String) -> Payload {
        // Images first — by declared conformance, then by sniffing.
        if let utType = UTType(type), utType.conforms(to: .image), let image = NSImage(data: data) {
            return .image(image)
        }

        // Binary property lists (very common for Apple-framework and
        // app-private types) decode into readable XML.
        if data.starts(with: Array("bplist".utf8)) {
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
               let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
               let string = String(data: xml, encoding: .utf8) {
                return .text("— binary property list, decoded —\n\n" + string)
            }
        }

        // Readable text (covers plain text, XML, RTF source, HTML, MusicXML…).
        if let string = String(data: data, encoding: .utf8), isMostlyPrintable(string) {
            return .text(string)
        }

        // Everything else: classic hex + ASCII dump.
        return .text(hexDump(data))
    }

    private static func isMostlyPrintable(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        let sample = string.prefix(2048)
        var control = 0
        for scalar in sample.unicodeScalars {
            if scalar.value < 32 && scalar != "\n" && scalar != "\t" && scalar != "\r" {
                control += 1
            }
        }
        return Double(control) / Double(sample.unicodeScalars.count) < 0.05
    }

    static func hexDump(_ data: Data, limit: Int = 16_384) -> String {
        let bytes = [UInt8](data.prefix(limit))
        var lines: [String] = []
        lines.reserveCapacity(bytes.count / 16 + 2)

        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = Array(bytes[offset..<min(offset + 16, bytes.count)])
            var hex = ""
            for (i, byte) in chunk.enumerated() {
                hex += String(format: "%02x ", byte)
                if i == 7 { hex += " " }
            }
            let paddedHex = hex.padding(toLength: 50, withPad: " ", startingAt: 0)
            let ascii = chunk.map { byte -> String in
                (32...126).contains(byte) ? String(UnicodeScalar(byte)) : "·"
            }.joined()
            lines.append(String(format: "%08x  ", offset) + paddedHex + " " + ascii)
        }

        if data.count > limit {
            lines.append("")
            lines.append("… truncated — showing \(Fmt.size(limit)) of \(Fmt.size(data.count)). Use EXPORT .BIN for the full payload.")
        }
        return lines.joined(separator: "\n")
    }
}
