#if DEBUG
    import AppKit

    /// Debug builds only: `-ClenvraUIDiagnostics <file>` appends every toolbar item added or removed and every split
    /// view resize to the file, so a UI test can tell whether an action rebuilt the toolbar or moved the sidebar.
    enum UIDiagnostics {
        private static var observers: [any NSObjectProtocol] = []

        static func start() {
            guard observers.isEmpty, let path = UserDefaults.standard.string(forKey: "ClenvraUIDiagnostics") else {
                return
            }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: .main) { note in
                    let item = note.userInfo?["item"] as? NSToolbarItem
                    write("toolbar \(id(note.object)) add \(item?.itemIdentifier.rawValue ?? "?")", to: path)
                },
                center.addObserver(forName: NSToolbar.didRemoveItemNotification, object: nil, queue: .main) { note in
                    let item = note.userInfo?["item"] as? NSToolbarItem
                    write("toolbar \(id(note.object)) remove \(item?.itemIdentifier.rawValue ?? "?")", to: path)
                },
                center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) {
                    note in
                    guard let split = note.object as? NSSplitView else { return }
                    let widths = split.arrangedSubviews.map { $0.isHidden ? "hidden" : "\(Int($0.frame.width))" }
                    write("split \(id(split)) \(widths.joined(separator: " "))", to: path)
                },
            ]
        }

        nonisolated private static func id(_ object: Any?) -> String {
            guard let object = object as AnyObject? else { return "-" }
            return String(UInt(bitPattern: ObjectIdentifier(object).hashValue) % 100_000)
        }

        nonisolated private static func write(_ line: String, to path: String) {
            let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
            guard let handle = FileHandle(forWritingAtPath: path) ?? create(path) else { return }
            handle.seekToEndOfFile()
            handle.write(Data("\(stamp) \(line)\n".utf8))
            try? handle.close()
        }

        nonisolated private static func create(_ path: String) -> FileHandle? {
            FileManager.default.createFile(atPath: path, contents: nil)
            return FileHandle(forWritingAtPath: path)
        }
    }
#endif
